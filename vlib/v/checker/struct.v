// Copyright (c) 2019-2022 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license that can be found in the LICENSE file.
module checker

import v.ast
import v.util

fn (mut c Checker) struct_decl(mut node ast.StructDecl) {
	util.timing_start(@METHOD)
	defer {
		util.timing_measure_cumulative(@METHOD)
	}
	mut struct_sym, struct_typ_idx := c.table.find_sym_and_type_idx(node.name)
	mut has_generic_types := false
	if mut struct_sym.info is ast.Struct {
		if node.language == .v && !c.is_builtin_mod && !struct_sym.info.is_anon {
			c.check_valid_pascal_case(node.name, 'struct name', node.pos)
		}
		for embed in node.embeds {
			if embed.typ.has_flag(.generic) {
				has_generic_types = true
			}
			embed_sym := c.table.sym(embed.typ)
			if embed_sym.kind != .struct_ {
				c.error('`${embed_sym.name}` is not a struct', embed.pos)
			} else {
				info := embed_sym.info as ast.Struct
				if info.is_heap && !embed.typ.is_ptr() {
					struct_sym.info.is_heap = true
				}
			}
			// Ensure each generic type of the embed was declared in the struct's definition
			if node.generic_types.len > 0 && embed.typ.has_flag(.generic) {
				embed_generic_names := c.table.generic_type_names(embed.typ)
				node_generic_names := node.generic_types.map(c.table.type_to_str(it))
				for name in embed_generic_names {
					if name !in node_generic_names {
						struct_generic_names := node_generic_names.join(', ')
						c.error('generic type name `${name}` is not mentioned in struct `${node.name}[${struct_generic_names}]`',
							embed.pos)
					}
				}
			}
		}
		if struct_sym.info.is_minify {
			node.fields.sort_with_compare(minify_sort_fn)
			struct_sym.info.fields.sort_with_compare(minify_sort_fn)
		}
		for attr in node.attrs {
			if attr.name == 'typedef' && node.language != .c {
				c.error('`typedef` attribute can only be used with C structs', node.pos)
			}
		}

		// Update .default_expr_typ for all fields in the struct:
		util.timing_start('Checker.struct setting default_expr_typ')
		old_expected_type := c.expected_type
		for mut field in node.fields {
			if field.has_default_expr {
				c.expected_type = field.typ
				field.default_expr_typ = c.expr(field.default_expr)
				for mut symfield in struct_sym.info.fields {
					if symfield.name == field.name {
						symfield.default_expr_typ = field.default_expr_typ
						break
					}
				}
			}
		}
		c.expected_type = old_expected_type
		util.timing_measure_cumulative('Checker.struct setting default_expr_typ')

		for i, field in node.fields {
			if field.typ.has_flag(.result) {
				c.error('struct field does not support storing Result', field.option_pos)
			}
			c.ensure_type_exists(field.typ, field.type_pos) or { return }
			c.ensure_generic_type_specify_type_names(field.typ, field.type_pos) or { return }
			if field.typ.has_flag(.generic) {
				has_generic_types = true
			}
			if node.language == .v {
				c.check_valid_snake_case(field.name, 'field name', field.pos)
			}
			sym := c.table.sym(field.typ)
			for j in 0 .. i {
				if field.name == node.fields[j].name {
					c.error('field name `${field.name}` duplicate', field.pos)
				}
			}
			if field.typ != 0 {
				if !field.typ.is_ptr() {
					if c.table.unaliased_type(field.typ) == struct_typ_idx {
						c.error('field `${field.name}` is part of `${node.name}`, they can not both have the same type',
							field.type_pos)
					}
				}
			}
			if sym.kind == .struct_ {
				info := sym.info as ast.Struct
				if info.is_heap && !field.typ.is_ptr() {
					struct_sym.info.is_heap = true
				}
				for ct in info.concrete_types {
					ct_sym := c.table.sym(ct)
					if ct_sym.kind == .placeholder {
						c.error('unknown type `${ct_sym.name}`', field.type_pos)
					}
				}
			}
			if sym.kind == .multi_return {
				c.error('cannot use multi return as field type', field.type_pos)
			}

			if sym.kind == .none_ {
				c.error('cannot use `none` as field type', field.type_pos)
			}

			if field.has_default_expr {
				c.expected_type = field.typ
				default_expr_type := c.expr(field.default_expr)
				if !field.typ.has_flag(.option) && !field.typ.has_flag(.result) {
					c.check_expr_opt_call(field.default_expr, default_expr_type)
				}
				struct_sym.info.fields[i].default_expr_typ = default_expr_type
				interface_implemented := sym.kind == .interface_
					&& c.type_implements(default_expr_type, field.typ, field.pos)
				c.check_expected(default_expr_type, field.typ) or {
					if sym.kind == .interface_ && interface_implemented {
						if !c.inside_unsafe && !default_expr_type.is_real_pointer() {
							if c.table.sym(default_expr_type).kind != .interface_ {
								c.mark_as_referenced(mut &node.fields[i].default_expr,
									true)
							}
						}
					} else {
						c.error('incompatible initializer for field `${field.name}`: ${err.msg()}',
							field.default_expr.pos())
					}
				}
				if field.default_expr.is_nil() {
					if !field.typ.is_real_pointer() && c.table.sym(field.typ).kind != .function {
						c.error('cannot assign `nil` to a non-pointer field', field.type_pos)
					}
				}
				// Check for unnecessary inits like ` = 0` and ` = ''`
				if field.typ.is_ptr() {
					if field.default_expr is ast.IntegerLiteral {
						if !c.inside_unsafe && !c.is_builtin_mod && field.default_expr.val == '0' {
							c.error('default value of `0` for references can only be used inside `unsafe`',
								field.default_expr.pos)
						}
					}
					continue
				}
				if field.typ in ast.unsigned_integer_type_idxs {
					if field.default_expr is ast.IntegerLiteral {
						if field.default_expr.val[0] == `-` {
							c.error('cannot assign negative value to unsigned integer type',
								field.default_expr.pos)
						}
					}
				}

				if field.typ.has_flag(.option) {
					if field.default_expr is ast.None {
						c.warn('unnecessary default value of `none`: struct fields are zeroed by default',
							field.default_expr.pos)
					}
				} else if field.typ.has_flag(.result) {
					// struct field does not support result. Nothing to do
				} else {
					match field.default_expr {
						ast.IntegerLiteral {
							if field.default_expr.val == '0' {
								c.warn('unnecessary default value of `0`: struct fields are zeroed by default',
									field.default_expr.pos)
							}
						}
						ast.StringLiteral {
							if field.default_expr.val == '' {
								c.warn("unnecessary default value of '': struct fields are zeroed by default",
									field.default_expr.pos)
							}
						}
						ast.BoolLiteral {
							if field.default_expr.val == false {
								c.warn('unnecessary default value `false`: struct fields are zeroed by default',
									field.default_expr.pos)
							}
						}
						else {}
					}
				}
			}
			// Ensure each generic type of the field was declared in the struct's definition
			if node.generic_types.len > 0 && field.typ.has_flag(.generic) {
				field_generic_names := c.table.generic_type_names(field.typ)
				node_generic_names := node.generic_types.map(c.table.type_to_str(it))
				for name in field_generic_names {
					if name !in node_generic_names {
						struct_generic_names := node_generic_names.join(', ')
						c.error('generic type name `${name}` is not mentioned in struct `${node.name}[${struct_generic_names}]`',
							field.type_pos)
					}
				}
			}
		}
		if node.generic_types.len == 0 && has_generic_types {
			c.error('generic struct `${node.name}` declaration must specify the generic type names, e.g. ${node.name}[T]',
				node.pos)
		}
	}
}

fn minify_sort_fn(a &ast.StructField, b &ast.StructField) int {
	if a.typ == b.typ {
		return 0
	}
	// push all bool fields to the end of the struct
	if a.typ == ast.bool_type_idx {
		if b.typ == ast.bool_type_idx {
			return 0
		}
		return 1
	} else if b.typ == ast.bool_type_idx {
		return -1
	}

	mut t := global_table
	a_sym := t.sym(a.typ)
	b_sym := t.sym(b.typ)

	// push all non-flag enums to the end too, just before the bool fields
	// TODO: support enums with custom field values as well
	if a_sym.info is ast.Enum {
		if !a_sym.info.is_flag && !a_sym.info.uses_exprs {
			if b_sym.kind == .enum_ {
				a_nr_vals := (a_sym.info as ast.Enum).vals.len
				b_nr_vals := (b_sym.info as ast.Enum).vals.len
				return if a_nr_vals > b_nr_vals {
					-1
				} else if a_nr_vals < b_nr_vals {
					1
				} else {
					0
				}
			}
			return 1
		}
	} else if b_sym.info is ast.Enum {
		if !b_sym.info.is_flag && !b_sym.info.uses_exprs {
			return -1
		}
	}

	a_size, a_align := t.type_size(a.typ)
	b_size, b_align := t.type_size(b.typ)
	return if a_align > b_align {
		-1
	} else if a_align < b_align {
		1
	} else if a_size > b_size {
		-1
	} else if a_size < b_size {
		1
	} else {
		0
	}
}

fn (mut c Checker) struct_init(mut node ast.StructInit, is_field_zero_struct_init bool) ast.Type {
	util.timing_start(@METHOD)
	defer {
		util.timing_measure_cumulative(@METHOD)
	}
	if node.typ == ast.void_type {
		// short syntax `foo(key:val, key2:val2)`
		if c.expected_type == ast.void_type {
			c.error('unexpected short struct syntax', node.pos)
			return ast.void_type
		}
		sym := c.table.sym(c.expected_type)
		if sym.kind == .array {
			node.typ = c.table.value_type(c.expected_type)
		} else {
			node.typ = c.expected_type
		}
	}
	struct_sym := c.table.sym(node.typ)
	if struct_sym.info is ast.Struct {
		// check if the generic param types have been defined
		for ct in struct_sym.info.concrete_types {
			ct_sym := c.table.sym(ct)
			if ct_sym.kind == .placeholder {
				c.error('unknown type `${ct_sym.name}`', node.pos)
			}
		}
		if struct_sym.info.generic_types.len > 0 && struct_sym.info.concrete_types.len == 0
			&& !node.is_short_syntax {
			if c.table.cur_concrete_types.len == 0 {
				c.error('generic struct init must specify type parameter, e.g. Foo[int]',
					node.pos)
			} else if node.generic_types.len == 0 {
				c.error('generic struct init must specify type parameter, e.g. Foo[T]',
					node.pos)
			} else if node.generic_types.len > 0
				&& node.generic_types.len != struct_sym.info.generic_types.len {
				c.error('generic struct init expects ${struct_sym.info.generic_types.len} generic parameter, but got ${node.generic_types.len}',
					node.pos)
			} else if node.generic_types.len > 0 && c.table.cur_fn != unsafe { nil } {
				for gtyp in node.generic_types {
					if !gtyp.has_flag(.generic) {
						continue
					}
					gtyp_name := c.table.sym(gtyp).name
					if gtyp_name !in c.table.cur_fn.generic_names {
						cur_generic_names := '(' + c.table.cur_fn.generic_names.join(',') + ')'
						c.error('generic struct init type parameter `${gtyp_name}` must be within the parameters `${cur_generic_names}` of the current generic function',
							node.pos)
						break
					}
				}
			}
		}
		if node.generic_types.len > 0 && struct_sym.info.generic_types.len == 0 {
			c.error('a non generic struct `${node.typ_str}` used like a generic struct',
				node.name_pos)
		}
	} else if struct_sym.info is ast.Alias {
		parent_sym := c.table.sym(struct_sym.info.parent_type)
		// e.g. ´x := MyMapAlias{}´, should be a cast to alias type ´x := MyMapAlias(map[...]...)´
		if parent_sym.kind == .map {
			alias_str := c.table.type_to_str(node.typ)
			map_str := c.table.type_to_str(struct_sym.info.parent_type)
			c.error('direct map alias init is not possible, use `${alias_str}(${map_str}{})` instead',
				node.pos)
			return ast.void_type
		}
	}
	// register generic struct type when current fn is generic fn
	if c.table.cur_fn != unsafe { nil } && c.table.cur_fn.generic_names.len > 0 {
		c.table.unwrap_generic_type(node.typ, c.table.cur_fn.generic_names, c.table.cur_concrete_types)
	}
	if !is_field_zero_struct_init {
		c.ensure_type_exists(node.typ, node.pos) or {}
	}
	type_sym := c.table.sym(node.typ)
	if !c.inside_unsafe && type_sym.kind == .sum_type {
		c.note('direct sum type init (`x := SumType{}`) will be removed soon', node.pos)
	}
	// Make sure the first letter is capital, do not allow e.g. `x := string{}`,
	// but `x := T{}` is ok.
	if !c.is_builtin_mod && !c.inside_unsafe && type_sym.language == .v
		&& c.table.cur_concrete_types.len == 0 {
		pos := type_sym.name.last_index('.') or { -1 }
		first_letter := type_sym.name[pos + 1]
		if !first_letter.is_capital()
			&& (type_sym.kind != .struct_ || !(type_sym.info as ast.Struct).is_anon)
			&& type_sym.kind != .placeholder {
			c.error('cannot initialize builtin type `${type_sym.name}`', node.pos)
		}
		if type_sym.kind == .enum_ && !c.pref.translated && !c.file.is_translated {
			c.error('cannot initialize enums', node.pos)
		}
	}
	if type_sym.kind == .sum_type && node.fields.len == 1 {
		sexpr := node.fields[0].expr.str()
		c.error('cast to sum type using `${type_sym.name}(${sexpr})` not `${type_sym.name}{${sexpr}}`',
			node.pos)
	}
	if type_sym.kind == .interface_ && type_sym.language != .js {
		c.error('cannot instantiate interface `${type_sym.name}`', node.pos)
	}
	if type_sym.info is ast.Alias {
		if type_sym.info.parent_type.is_number() {
			c.error('cannot instantiate number type alias `${type_sym.name}`', node.pos)
			return ast.void_type
		}
	}
	// allow init structs from generic if they're private except the type is from builtin module
	if !node.has_update_expr && !type_sym.is_pub && type_sym.kind != .placeholder
		&& type_sym.language != .c && (type_sym.mod != c.mod && !(node.typ.has_flag(.generic)
		&& type_sym.mod != 'builtin')) && !is_field_zero_struct_init {
		c.error('type `${type_sym.name}` is private', node.pos)
	}
	if type_sym.kind == .struct_ {
		info := type_sym.info as ast.Struct
		if info.attrs.len > 0 && info.attrs[0].name == 'noinit' && type_sym.mod != c.mod {
			c.error('struct `${type_sym.name}` is declared with a `[noinit]` attribute, so ' +
				'it cannot be initialized with `${type_sym.name}{}`', node.pos)
		}
	}
	if type_sym.name.len == 1 && c.table.cur_fn != unsafe { nil }
		&& c.table.cur_fn.generic_names.len == 0 {
		c.error('unknown struct `${type_sym.name}`', node.pos)
		return ast.void_type
	}
	match type_sym.kind {
		.placeholder {
			c.error('unknown struct: ${type_sym.name}', node.pos)
			return ast.void_type
		}
		.any {
			// `T{ foo: 22 }`
			for mut field in node.fields {
				field.typ = c.expr(field.expr)
				field.expected_type = field.typ
			}
			sym := c.table.sym(c.unwrap_generic(node.typ))
			if sym.kind == .struct_ {
				info := sym.info as ast.Struct
				if node.no_keys && node.fields.len != info.fields.len {
					fname := if info.fields.len != 1 { 'fields' } else { 'field' }
					c.error('initializing struct `${sym.name}` needs `${info.fields.len}` ${fname}, but got `${node.fields.len}`',
						node.pos)
				}
			}
		}
		// string & array are also structs but .kind of string/array
		.struct_, .string, .array, .alias {
			mut info := ast.Struct{}
			if type_sym.kind == .alias {
				info_t := type_sym.info as ast.Alias
				sym := c.table.sym(info_t.parent_type)
				if sym.kind == .placeholder { // pending import symbol did not resolve
					c.error('unknown struct: ${type_sym.name}', node.pos)
					return ast.void_type
				}
				if sym.kind == .struct_ {
					info = sym.info as ast.Struct
				} else {
					c.error('alias type name: ${sym.name} is not struct type', node.pos)
				}
			} else {
				info = type_sym.info as ast.Struct
			}
			if node.no_keys {
				exp_len := info.fields.len
				got_len := node.fields.len
				if exp_len != got_len && !c.pref.translated {
					// XTODO remove !translated check
					amount := if exp_len < got_len { 'many' } else { 'few' }
					c.error('too ${amount} fields in `${type_sym.name}` literal (expecting ${exp_len}, got ${got_len})',
						node.pos)
				}
			}
			mut info_fields_sorted := []ast.StructField{}
			if node.no_keys {
				info_fields_sorted = info.fields.clone()
				info_fields_sorted.sort(a.i < b.i)
			}
			mut inited_fields := []string{}
			for i, mut field in node.fields {
				mut field_info := ast.StructField{}
				mut field_name := ''
				if node.no_keys {
					if i >= info.fields.len {
						// It doesn't make sense to check for fields that don't exist.
						// We should just stop here.
						break
					}
					field_info = info_fields_sorted[i]
					field_name = field_info.name
					node.fields[i].name = field_name
				} else {
					field_name = field.name
					mut exists := true
					field_info = c.table.find_field_with_embeds(type_sym, field_name) or {
						exists = false
						ast.StructField{}
					}
					if !exists {
						existing_fields := c.table.struct_fields(type_sym).map(it.name)
						c.error(util.new_suggestion(field.name, existing_fields).say('unknown field `${field.name}` in struct literal of type `${type_sym.name}`'),
							field.pos)
						continue
					}
					if field_name in inited_fields {
						c.error('duplicate field name in struct literal: `${field_name}`',
							field.pos)
						continue
					}
				}
				mut expr_type := ast.Type(0)
				mut expected_type := ast.Type(0)
				inited_fields << field_name
				field_type_sym := c.table.sym(field_info.typ)
				expected_type = field_info.typ
				c.expected_type = expected_type
				expr_type = c.expr(field.expr)
				if expr_type == ast.void_type {
					c.error('`${field.expr}` (no value) used as value', field.pos)
				}
				if !field_info.typ.has_flag(.option) && !field.typ.has_flag(.result) {
					expr_type = c.check_expr_opt_call(field.expr, expr_type)
				}
				expr_type_sym := c.table.sym(expr_type)
				if field_type_sym.kind == .voidptr && expr_type_sym.kind == .struct_
					&& !expr_type.is_ptr() {
					c.error('allocate on the heap for use in other functions', field.pos)
				}
				if field_type_sym.kind == .interface_ {
					if c.type_implements(expr_type, field_info.typ, field.pos) {
						if !c.inside_unsafe && expr_type_sym.kind != .interface_
							&& !expr_type.is_real_pointer() {
							c.mark_as_referenced(mut &field.expr, true)
						}
					}
				} else if expr_type != ast.void_type && expr_type_sym.kind != .placeholder
					&& !field_info.typ.has_flag(.generic) {
					c.check_expected(c.unwrap_generic(expr_type), c.unwrap_generic(field_info.typ)) or {
						c.error('cannot assign to field `${field_info.name}`: ${err.msg()}',
							field.pos)
					}
				}
				if field_info.typ.has_flag(.shared_f) {
					if !expr_type.has_flag(.shared_f) && expr_type.is_ptr() {
						c.error('`shared` field must be initialized with `shared` or value',
							field.pos)
					}
				} else {
					if field_info.typ.is_ptr() && !expr_type.is_real_pointer()
						&& field.expr.str() != '0' {
						c.error('reference field must be initialized with reference',
							field.pos)
					}
				}
				node.fields[i].typ = expr_type
				node.fields[i].expected_type = field_info.typ

				if expr_type.is_ptr() && expected_type.is_ptr() {
					if mut field.expr is ast.Ident {
						if mut field.expr.obj is ast.Var {
							mut obj := unsafe { &field.expr.obj }
							if c.fn_scope != unsafe { nil } {
								obj = c.fn_scope.find_var(obj.name) or { obj }
							}
							if obj.is_stack_obj && !c.inside_unsafe {
								sym := c.table.sym(obj.typ.set_nr_muls(0))
								if !sym.is_heap() && !c.pref.translated && !c.file.is_translated {
									suggestion := if sym.kind == .struct_ {
										'declaring `${sym.name}` as `[heap]`'
									} else {
										'wrapping the `${sym.name}` object in a `struct` declared as `[heap]`'
									}
									c.error('`${field.expr.name}` cannot be assigned outside `unsafe` blocks as it might refer to an object stored on stack. Consider ${suggestion}.',
										field.expr.pos)
								}
							}
						}
					}
				}
				if field_info.typ in ast.unsigned_integer_type_idxs {
					if mut field.expr is ast.IntegerLiteral {
						if field.expr.val[0] == `-` {
							c.error('cannot assign negative value to unsigned integer type',
								field.expr.pos)
						}
					}
				}
			}
			// Check uninitialized refs/sum types
			// The variable `fields` contains two parts, the first part is the same as info.fields,
			// and the second part is all fields embedded in the structure
			// If the return value data composition form in `c.table.struct_fields()` is modified,
			// need to modify here accordingly.
			fields := c.table.struct_fields(type_sym)
			mut checked_types := []ast.Type{}
			for i, field in fields {
				if field.name in inited_fields {
					continue
				}
				sym := c.table.sym(field.typ)
				if field.name.len > 0 && field.name[0].is_capital() && sym.info is ast.Struct
					&& sym.language == .v {
					// struct embeds
					continue
				}
				if field.has_default_expr {
					if i < info.fields.len && field.default_expr_typ == 0 {
						if field.default_expr is ast.StructInit {
							idx := c.table.find_type_idx(field.default_expr.typ_str)
							if idx != 0 {
								info.fields[i].default_expr_typ = ast.new_type(idx)
							}
						} else if field.default_expr.is_nil() {
							if field.typ.is_real_pointer() {
								info.fields[i].default_expr_typ = field.typ
							}
						} else {
							if const_field := c.table.global_scope.find_const('${field.default_expr}') {
								info.fields[i].default_expr_typ = const_field.typ
							}
						}
					}
					continue
				}
				if field.typ.is_ptr() && !field.typ.has_flag(.shared_f) && !node.has_update_expr
					&& !c.pref.translated && !c.file.is_translated {
					c.warn('reference field `${type_sym.name}.${field.name}` must be initialized',
						node.pos)
					continue
				}
				if sym.kind == .struct_ {
					c.check_ref_fields_initialized(sym, mut checked_types, '${type_sym.name}.${field.name}',
						node)
				} else if sym.kind == .alias {
					parent_sym := c.table.sym((sym.info as ast.Alias).parent_type)
					if parent_sym.kind == .struct_ {
						c.check_ref_fields_initialized(parent_sym, mut checked_types,
							'${type_sym.name}.${field.name}', node)
					}
				}
				// Do not allow empty uninitialized interfaces
				mut has_noinit := false
				for attr in field.attrs {
					if attr.name == 'noinit' {
						has_noinit = true
						break
					}
				}
				if sym.kind == .interface_ && (!has_noinit && sym.language != .js) {
					// TODO: should be an error instead, but first `ui` needs updating.
					c.note('interface field `${type_sym.name}.${field.name}` must be initialized',
						node.pos)
				}
				// Do not allow empty uninitialized sum types
				/*
				sym := c.table.sym(field.typ)
				if sym.kind == .sum_type {
					c.warn('sum type field `${type_sym.name}.$field.name` must be initialized',
						node.pos)
				}
				*/
				// Check for `[required]` struct attr
				if field.attrs.contains('required') && !node.no_keys && !node.has_update_expr {
					mut found := false
					for init_field in node.fields {
						if field.name == init_field.name {
							found = true
							break
						}
					}
					if !found {
						c.error('field `${type_sym.name}.${field.name}` must be initialized',
							node.pos)
					}
				}
				if !field.has_default_expr && field.name !in inited_fields && !field.typ.is_ptr()
					&& !field.typ.has_flag(.option) && c.table.final_sym(field.typ).kind == .struct_ {
					mut zero_struct_init := ast.StructInit{
						pos: node.pos
						typ: field.typ
					}
					c.struct_init(mut zero_struct_init, true)
				}
			}
			// println('>> checked_types.len: $checked_types.len | checked_types: $checked_types | type_sym: $type_sym.name ')
		}
		else {}
	}
	if node.has_update_expr {
		update_type := c.expr(node.update_expr)
		node.update_expr_type = update_type
		if node.update_expr is ast.ComptimeSelector {
			c.error('cannot use struct update syntax in compile time expressions', node.update_expr_pos)
		} else if c.table.final_sym(update_type).kind != .struct_ {
			s := c.table.type_to_str(update_type)
			c.error('expected struct, found `${s}`', node.update_expr.pos())
		} else if update_type != node.typ {
			from_sym := c.table.sym(update_type)
			to_sym := c.table.sym(node.typ)
			from_info := from_sym.info as ast.Struct
			to_info := to_sym.info as ast.Struct
			// TODO this check is too strict
			if !c.check_struct_signature(from_info, to_info)
				|| !c.check_struct_signature_init_fields(from_info, to_info, node) {
				c.error('struct `${from_sym.name}` is not compatible with struct `${to_sym.name}`',
					node.update_expr.pos())
			}
		}
	}
	if struct_sym.info is ast.Struct {
		if struct_sym.info.generic_types.len > 0 && struct_sym.info.concrete_types.len == 0 {
			if node.is_short_syntax {
				concrete_types := c.infer_struct_generic_types(node.typ, node)
				if concrete_types.len > 0 {
					generic_names := struct_sym.info.generic_types.map(c.table.sym(it).name)
					node.typ = c.table.unwrap_generic_type(node.typ, generic_names, concrete_types)
				}
			}
		}
	}
	return node.typ
}

// Recursively check whether the struct type field is initialized
fn (mut c Checker) check_ref_fields_initialized(struct_sym &ast.TypeSymbol, mut checked_types []ast.Type, linked_name string, node &ast.StructInit) {
	if c.pref.translated || c.file.is_translated {
		return
	}
	if struct_sym.kind == .struct_ && struct_sym.language == .c
		&& (struct_sym.info as ast.Struct).is_typedef {
		return
	}
	fields := c.table.struct_fields(struct_sym)
	for field in fields {
		sym := c.table.sym(field.typ)
		if field.name.len > 0 && field.name[0].is_capital() && sym.info is ast.Struct
			&& sym.language == .v {
			// an embedded struct field
			continue
		}
		if field.typ.is_ptr() && !field.typ.has_flag(.shared_f) && !field.has_default_expr {
			c.warn('reference field `${linked_name}.${field.name}` must be initialized (part of struct `${struct_sym.name}`)',
				node.pos)
			continue
		}
		if sym.kind == .struct_ {
			if sym.language == .c && (sym.info as ast.Struct).is_typedef {
				continue
			}
			if field.typ in checked_types {
				continue
			}
			checked_types << field.typ
			c.check_ref_fields_initialized(sym, mut checked_types, '${linked_name}.${field.name}',
				node)
		} else if sym.kind == .alias {
			psym := c.table.sym((sym.info as ast.Alias).parent_type)
			if psym.kind == .struct_ {
				checked_types << field.typ
				c.check_ref_fields_initialized(psym, mut checked_types, '${linked_name}.${field.name}',
					node)
			}
		}
	}
}
