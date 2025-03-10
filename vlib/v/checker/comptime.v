// Copyright (c) 2019-2022 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license that can be found in the LICENSE file.
module checker

import os
import v.ast
import v.pref
import v.token
import v.util
import v.pkgconfig
import v.checker.constants

fn (mut c Checker) comptime_call(mut node ast.ComptimeCall) ast.Type {
	if node.left !is ast.EmptyExpr {
		node.left_type = c.expr(node.left)
	}
	if node.method_name == 'compile_error' {
		c.error(node.args_var, node.pos)
		return ast.void_type
	} else if node.method_name == 'compile_warn' {
		c.warn(node.args_var, node.pos)
		return ast.void_type
	}
	if node.is_env {
		env_value := util.resolve_env_value("\$env('${node.args_var}')", false) or {
			c.error(err.msg(), node.env_pos)
			return ast.string_type
		}
		node.env_value = env_value
		return ast.string_type
	}
	if node.is_embed {
		if node.args.len == 1 {
			embed_arg := node.args[0]
			mut raw_path := ''
			if embed_arg.expr is ast.StringLiteral {
				raw_path = embed_arg.expr.val
			} else if embed_arg.expr is ast.Ident {
				if var := c.fn_scope.find_var(embed_arg.expr.name) {
					if var.expr is ast.StringLiteral {
						raw_path = var.expr.val
					}
				}
			}
			mut escaped_path := raw_path.replace('/', os.path_separator)
			// Validate that the epath exists, and that it is actually a file.
			if escaped_path == '' {
				c.error('supply a valid relative or absolute file path to the file to embed, that is known at compile time',
					node.pos)
				return ast.string_type
			}
			abs_path := os.real_path(escaped_path)
			// check absolute path first
			if !os.exists(abs_path) {
				// ... look relative to the source file:
				escaped_path = os.real_path(os.join_path_single(os.dir(c.file.path), escaped_path))
				if !os.exists(escaped_path) {
					c.error('"${escaped_path}" does not exist so it cannot be embedded',
						node.pos)
					return ast.string_type
				}
				if !os.is_file(escaped_path) {
					c.error('"${escaped_path}" is not a file so it cannot be embedded',
						node.pos)
					return ast.string_type
				}
			} else {
				escaped_path = abs_path
			}
			node.embed_file.rpath = raw_path
			node.embed_file.apath = escaped_path
		}
		// c.file.embedded_files << node.embed_file
		if node.embed_file.compression_type !in constants.valid_comptime_compression_types {
			supported := constants.valid_comptime_compression_types.map('.${it}').join(', ')
			c.error('not supported compression type: .${node.embed_file.compression_type}. supported: ${supported}',
				node.pos)
		}
		return c.table.find_type_idx('v.embed_file.EmbedFileData')
	}
	if node.is_vweb {
		// TODO assoc parser bug
		save_cur_fn := c.table.cur_fn
		pref_ := *c.pref
		pref2 := &pref.Preferences{
			...pref_
			is_vweb: true
		}
		mut c2 := new_checker(c.table, pref2)
		c2.comptime_call_pos = node.pos.pos
		c2.check(node.vweb_tmpl)
		c.warnings << c2.warnings
		c.errors << c2.errors
		c.notices << c2.notices
		c.nr_warnings += c2.nr_warnings
		c.nr_errors += c2.nr_errors
		c.nr_notices += c2.nr_notices

		c.table.cur_fn = save_cur_fn
	}
	if node.method_name == 'html' {
		rtyp := c.table.find_type_idx('vweb.Result')
		node.result_type = rtyp
		return rtyp
	}
	if node.method_name == 'method' {
		if c.inside_anon_fn && 'method' !in c.cur_anon_fn.inherited_vars.map(it.name) {
			c.error('undefined ident `method` in the anonymous function', node.pos)
		}
		for i, arg in node.args {
			// check each arg expression
			node.args[i].typ = c.expr(arg.expr)
		}
		// assume string for now
		return ast.string_type
	}
	if node.is_vweb {
		return ast.string_type
	}
	// s.$my_str()
	v := node.scope.find_var(node.method_name) or {
		c.error('unknown identifier `${node.method_name}`', node.method_pos)
		return ast.void_type
	}
	if v.typ != ast.string_type {
		s := c.expected_msg(v.typ, ast.string_type)
		c.error('invalid string method call: ${s}', node.method_pos)
		return ast.void_type
	}
	// note: we should use a compile-time evaluation function rather than handle here
	// mut variables will not work after init
	mut method_name := ''
	if v.expr is ast.StringLiteral {
		method_name = v.expr.val
	} else {
		c.error('todo: not a string literal', node.method_pos)
	}
	left_sym := c.table.sym(c.unwrap_generic(node.left_type))
	f := left_sym.find_method(method_name) or {
		c.error('could not find method `${method_name}`', node.method_pos)
		return ast.void_type
	}
	node.result_type = f.return_type
	return f.return_type
}

fn (mut c Checker) comptime_selector(mut node ast.ComptimeSelector) ast.Type {
	node.left_type = c.expr(node.left)
	mut expr_type := c.unwrap_generic(c.expr(node.field_expr))
	expr_sym := c.table.sym(expr_type)
	if expr_type != ast.string_type {
		c.error('expected `string` instead of `${expr_sym.name}` (e.g. `field.name`)',
			node.field_expr.pos())
	}
	if mut node.field_expr is ast.SelectorExpr {
		left_pos := node.field_expr.expr.pos()
		if c.comptime_fields_type.len == 0 {
			c.error('compile time field access can only be used when iterating over `T.fields`',
				left_pos)
		}
		expr_type = c.get_comptime_selector_type(node, ast.void_type)
		if expr_type != ast.void_type {
			return expr_type
		}
		expr_name := node.field_expr.expr.str()
		if expr_name in c.comptime_fields_type {
			return c.comptime_fields_type[expr_name]
		}
		c.error('unknown `\$for` variable `${expr_name}`', left_pos)
	} else {
		c.error('expected selector expression e.g. `$(field.name)`', node.field_expr.pos())
	}
	return ast.void_type
}

fn (mut c Checker) comptime_for(node ast.ComptimeFor) {
	typ := c.unwrap_generic(node.typ)
	sym := c.table.final_sym(typ)
	if sym.kind == .placeholder || typ.has_flag(.generic) {
		c.error('unknown type `${sym.name}`', node.typ_pos)
	}
	if node.kind == .fields {
		if sym.kind in [.struct_, .interface_] {
			mut fields := []ast.StructField{}
			match sym.info {
				ast.Struct {
					fields = sym.info.fields.clone()
				}
				ast.Interface {
					fields = sym.info.fields.clone()
				}
				else {
					c.error('comptime field lookup supports only structs and interfaces currently, and ${sym.name} is neither',
						node.typ_pos)
					return
				}
			}
			c.inside_comptime_for_field = true
			for field in fields {
				c.comptime_for_field_value = field
				c.comptime_for_field_var = node.val_var
				c.comptime_fields_type[node.val_var] = node.typ
				c.comptime_fields_default_type = field.typ
				c.stmts(node.stmts)

				unwrapped_expr_type := c.unwrap_generic(field.typ)
				tsym := c.table.sym(unwrapped_expr_type)
				c.table.dumps[int(unwrapped_expr_type.clear_flag(.option).clear_flag(.result).clear_flag(.atomic_f))] = tsym.cname
			}
			c.comptime_for_field_var = ''
			c.inside_comptime_for_field = false
		}
	} else {
		c.stmts(node.stmts)
	}
}

// comptime const eval
fn (mut c Checker) eval_comptime_const_expr(expr ast.Expr, nlevel int) ?ast.ComptTimeConstValue {
	if nlevel > 100 {
		// protect against a too deep comptime eval recursion
		return none
	}
	match expr {
		ast.ParExpr {
			return c.eval_comptime_const_expr(expr.expr, nlevel + 1)
		}
		// ast.EnumVal {
		//	c.note('>>>>>>>> expr: $expr', expr.pos)
		//	return expr.val.i64()
		// }
		ast.SizeOf {
			s, _ := c.table.type_size(expr.typ)
			return s
		}
		ast.FloatLiteral {
			x := expr.val.f64()
			return x
		}
		ast.IntegerLiteral {
			x := expr.val.u64()
			if x > 9223372036854775807 {
				return x
			}
			return expr.val.i64()
		}
		ast.StringLiteral {
			return util.smart_quote(expr.val, expr.is_raw)
		}
		ast.CharLiteral {
			runes := expr.val.runes()
			if runes.len > 0 {
				return runes[0]
			}
			return none
		}
		ast.Ident {
			if expr.obj is ast.ConstField {
				// an existing constant?
				return c.eval_comptime_const_expr(expr.obj.expr, nlevel + 1)
			}
		}
		ast.CastExpr {
			cast_expr_value := c.eval_comptime_const_expr(expr.expr, nlevel + 1) or { return none }
			if expr.typ == ast.i8_type {
				return cast_expr_value.i8() or { return none }
			}
			if expr.typ == ast.i16_type {
				return cast_expr_value.i16() or { return none }
			}
			if expr.typ == ast.int_type {
				return cast_expr_value.int() or { return none }
			}
			if expr.typ == ast.i64_type {
				return cast_expr_value.i64() or { return none }
			}
			//
			if expr.typ == ast.u8_type {
				return cast_expr_value.u8() or { return none }
			}
			if expr.typ == ast.u16_type {
				return cast_expr_value.u16() or { return none }
			}
			if expr.typ == ast.u32_type {
				return cast_expr_value.u32() or { return none }
			}
			if expr.typ == ast.u64_type {
				return cast_expr_value.u64() or { return none }
			}
			//
			if expr.typ == ast.f32_type {
				return cast_expr_value.f32() or { return none }
			}
			if expr.typ == ast.f64_type {
				return cast_expr_value.f64() or { return none }
			}
			if expr.typ == ast.voidptr_type || expr.typ == ast.nil_type {
				ptrvalue := cast_expr_value.voidptr() or { return none }
				return ast.ComptTimeConstValue(ptrvalue)
			}
		}
		ast.InfixExpr {
			left := c.eval_comptime_const_expr(expr.left, nlevel + 1)?
			right := c.eval_comptime_const_expr(expr.right, nlevel + 1)?
			if left is string && right is string {
				match expr.op {
					.plus {
						return left + right
					}
					else {
						return none
					}
				}
			} else if left is u64 && right is i64 {
				match expr.op {
					.plus { return i64(left) + i64(right) }
					.minus { return i64(left) - i64(right) }
					.mul { return i64(left) * i64(right) }
					.div { return i64(left) / i64(right) }
					.mod { return i64(left) % i64(right) }
					.xor { return i64(left) ^ i64(right) }
					.pipe { return i64(left) | i64(right) }
					.amp { return i64(left) & i64(right) }
					.left_shift { return i64(u64(left) << i64(right)) }
					.right_shift { return i64(u64(left) >> i64(right)) }
					.unsigned_right_shift { return i64(u64(left) >>> i64(right)) }
					else { return none }
				}
			} else if left is i64 && right is u64 {
				match expr.op {
					.plus { return i64(left) + i64(right) }
					.minus { return i64(left) - i64(right) }
					.mul { return i64(left) * i64(right) }
					.div { return i64(left) / i64(right) }
					.mod { return i64(left) % i64(right) }
					.xor { return i64(left) ^ i64(right) }
					.pipe { return i64(left) | i64(right) }
					.amp { return i64(left) & i64(right) }
					.left_shift { return i64(u64(left) << i64(right)) }
					.right_shift { return i64(u64(left) >> i64(right)) }
					.unsigned_right_shift { return i64(u64(left) >>> i64(right)) }
					else { return none }
				}
			} else if left is u64 && right is u64 {
				match expr.op {
					.plus { return left + right }
					.minus { return left - right }
					.mul { return left * right }
					.div { return left / right }
					.mod { return left % right }
					.xor { return left ^ right }
					.pipe { return left | right }
					.amp { return left & right }
					.left_shift { return left << right }
					.right_shift { return left >> right }
					.unsigned_right_shift { return left >>> right }
					else { return none }
				}
			} else if left is i64 && right is i64 {
				match expr.op {
					.plus { return left + right }
					.minus { return left - right }
					.mul { return left * right }
					.div { return left / right }
					.mod { return left % right }
					.xor { return left ^ right }
					.pipe { return left | right }
					.amp { return left & right }
					.left_shift { return i64(u64(left) << right) }
					.right_shift { return i64(u64(left) >> right) }
					.unsigned_right_shift { return i64(u64(left) >>> right) }
					else { return none }
				}
			} else if left is u8 && right is u8 {
				match expr.op {
					.plus { return left + right }
					.minus { return left - right }
					.mul { return left * right }
					.div { return left / right }
					.mod { return left % right }
					.xor { return left ^ right }
					.pipe { return left | right }
					.amp { return left & right }
					.left_shift { return left << right }
					.right_shift { return left >> right }
					.unsigned_right_shift { return left >>> right }
					else { return none }
				}
			}
		}
		ast.IfExpr {
			if !expr.is_comptime {
				return none
			}
			for i in 0 .. expr.branches.len {
				branch := expr.branches[i]
				if !expr.has_else || i < expr.branches.len - 1 {
					if c.comptime_if_branch(branch.cond, branch.pos) == .eval {
						last_stmt := branch.stmts.last()
						if last_stmt is ast.ExprStmt {
							return c.eval_comptime_const_expr(last_stmt.expr, nlevel + 1)
						}
					}
				} else {
					last_stmt := branch.stmts.last()
					if last_stmt is ast.ExprStmt {
						return c.eval_comptime_const_expr(last_stmt.expr, nlevel + 1)
					}
				}
			}
		}
		// ast.ArrayInit {}
		// ast.PrefixExpr {
		//	c.note('prefixexpr: $expr', expr.pos)
		// }
		else {
			// eprintln('>>> nlevel: $nlevel | another $expr.type_name() | $expr ')
			return none
		}
	}
	return none
}

fn (mut c Checker) verify_vweb_params_for_method(node ast.Fn) (bool, int, int) {
	margs := node.params.len - 1 // first arg is the receiver/this
	if node.attrs.len == 0 {
		// allow non custom routed methods, with 1:1 mapping
		return true, -1, margs
	}
	if node.params.len > 1 {
		for param in node.params[1..] {
			param_sym := c.table.final_sym(param.typ)
			if !(param_sym.is_string() || param_sym.is_number() || param_sym.is_float()
				|| param_sym.kind == .bool) {
				c.error('invalid type `${param_sym.name}` for parameter `${param.name}` in vweb app method `${node.name}`',
					param.pos)
			}
		}
	}
	mut route_attributes := 0
	for a in node.attrs {
		if a.name.starts_with('/') {
			route_attributes += a.name.count(':')
		}
	}
	return route_attributes == margs, route_attributes, margs
}

fn (mut c Checker) verify_all_vweb_routes() {
	if c.vweb_gen_types.len == 0 {
		return
	}
	c.table.used_vweb_types = c.vweb_gen_types
	typ_vweb_result := c.table.find_type_idx('vweb.Result')
	old_file := c.file
	for vgt in c.vweb_gen_types {
		sym_app := c.table.sym(vgt)
		for m in sym_app.methods {
			if m.return_type == typ_vweb_result {
				is_ok, nroute_attributes, nargs := c.verify_vweb_params_for_method(m)
				if !is_ok {
					f := unsafe { &ast.FnDecl(m.source_fn) }
					if f == unsafe { nil } {
						continue
					}
					if f.return_type == typ_vweb_result && f.receiver.typ == m.params[0].typ
						&& f.name == m.name && !f.attrs.contains('post') {
						c.change_current_file(f.source_file) // setup of file path for the warning
						c.warn('mismatched parameters count between vweb method `${sym_app.name}.${m.name}` (${nargs}) and route attribute ${m.attrs} (${nroute_attributes})',
							f.pos)
					}
				}
			}
		}
	}
	c.change_current_file(old_file)
}

fn (mut c Checker) evaluate_once_comptime_if_attribute(mut node ast.Attr) bool {
	if node.ct_evaled {
		return node.ct_skip
	}
	if node.ct_expr is ast.Ident {
		if node.ct_opt {
			if node.ct_expr.name in constants.valid_comptime_not_user_defined {
				c.error('option `[if expression ?]` tags, can be used only for user defined identifiers',
					node.pos)
				node.ct_skip = true
			} else {
				node.ct_skip = node.ct_expr.name !in c.pref.compile_defines
			}
			node.ct_evaled = true
			return node.ct_skip
		} else {
			if node.ct_expr.name !in constants.valid_comptime_not_user_defined {
				c.note('`[if ${node.ct_expr.name}]` is deprecated. Use `[if ${node.ct_expr.name} ?]` instead',
					node.pos)
				node.ct_skip = node.ct_expr.name !in c.pref.compile_defines
				node.ct_evaled = true
				return node.ct_skip
			} else {
				if node.ct_expr.name in c.pref.compile_defines {
					// explicitly allow custom user overrides with `-d linux` for example, for easier testing:
					node.ct_skip = false
					node.ct_evaled = true
					return node.ct_skip
				}
			}
		}
	}
	c.inside_ct_attr = true
	node.ct_skip = if c.comptime_if_branch(node.ct_expr, node.pos) == .skip { true } else { false }
	c.inside_ct_attr = false
	node.ct_evaled = true
	return node.ct_skip
}

enum ComptimeBranchSkipState {
	eval
	skip
	unknown
}

// comptime_if_branch checks the condition of a compile-time `if` branch. It returns `true`
// if that branch's contents should be skipped (targets a different os for example)
fn (mut c Checker) comptime_if_branch(cond ast.Expr, pos token.Pos) ComptimeBranchSkipState {
	// TODO: better error messages here
	match cond {
		ast.BoolLiteral {
			return if cond.val { .eval } else { .skip }
		}
		ast.ParExpr {
			return c.comptime_if_branch(cond.expr, pos)
		}
		ast.PrefixExpr {
			if cond.op != .not {
				c.error('invalid `\$if` condition', cond.pos)
			}
			reversed := c.comptime_if_branch(cond.right, cond.pos)
			return if reversed == .eval {
				.skip
			} else if reversed == .skip {
				.eval
			} else {
				reversed
			}
		}
		ast.PostfixExpr {
			if cond.op != .question {
				c.error('invalid \$if postfix operator', cond.pos)
			} else if cond.expr is ast.Ident {
				return if cond.expr.name in c.pref.compile_defines_all { .eval } else { .skip }
			} else {
				c.error('invalid `\$if` condition', cond.pos)
			}
		}
		ast.InfixExpr {
			match cond.op {
				.and {
					l := c.comptime_if_branch(cond.left, cond.pos)
					r := c.comptime_if_branch(cond.right, cond.pos)
					if l == .unknown || r == .unknown {
						return .unknown
					}
					return if l == .eval && r == .eval { .eval } else { .skip }
				}
				.logical_or {
					l := c.comptime_if_branch(cond.left, cond.pos)
					r := c.comptime_if_branch(cond.right, cond.pos)
					if l == .unknown || r == .unknown {
						return .unknown
					}
					return if l == .eval || r == .eval { .eval } else { .skip }
				}
				.key_is, .not_is {
					if cond.left is ast.TypeNode && cond.right is ast.TypeNode {
						// `$if Foo is Interface {`
						sym := c.table.sym(cond.right.typ)
						if sym.kind != .interface_ {
							c.expr(cond.left)
							// c.error('`$sym.name` is not an interface', cond.right.pos())
						}
						return .unknown
					} else if cond.left is ast.TypeNode && cond.right is ast.ComptimeType {
						left := cond.left as ast.TypeNode
						checked_type := c.unwrap_generic(left.typ)
						return if c.table.is_comptime_type(checked_type, cond.right) {
							.eval
						} else {
							.skip
						}
					} else if cond.left in [ast.Ident, ast.SelectorExpr, ast.TypeNode] {
						// `$if method.@type is string`
						c.expr(cond.left)
						return .unknown
					} else {
						c.error('invalid `\$if` condition: expected a type or a selector expression or an interface check',
							cond.left.pos())
					}
				}
				.eq, .ne {
					if cond.left is ast.SelectorExpr
						&& cond.right in [ast.IntegerLiteral, ast.StringLiteral] {
						return .unknown
						// $if method.args.len == 1
					} else if cond.left is ast.SelectorExpr
						&& c.check_comptime_is_field_selector_bool(cond.left as ast.SelectorExpr) {
						// field.is_public (from T.fields)
					} else if cond.right is ast.SelectorExpr
						&& c.check_comptime_is_field_selector_bool(cond.right as ast.SelectorExpr) {
						// field.is_public (from T.fields)
					} else if cond.left is ast.Ident {
						// $if version == 2
						left_type := c.expr(cond.left)
						right_type := c.expr(cond.right)
						expr := c.find_definition(cond.left) or {
							c.error(err.msg(), cond.left.pos)
							return .unknown
						}
						if !c.check_types(right_type, left_type) {
							left_name := c.table.type_to_str(left_type)
							right_name := c.table.type_to_str(right_type)
							c.error('mismatched types `${left_name}` and `${right_name}`',
								cond.pos)
						}
						// :)
						// until `v.eval` is stable, I can't think of a better way to do this
						different := expr.str() != cond.right.str()
						return if cond.op == .eq {
							if different {
								ComptimeBranchSkipState.skip
							} else {
								ComptimeBranchSkipState.eval
							}
						} else {
							if different {
								ComptimeBranchSkipState.eval
							} else {
								ComptimeBranchSkipState.skip
							}
						}
					} else {
						c.error('invalid `\$if` condition: ${cond.left.type_name()}1',
							cond.pos)
					}
				}
				.key_in, .not_in {
					if cond.left in [ast.SelectorExpr, ast.TypeNode] && cond.right is ast.ArrayInit {
						for expr in cond.right.exprs {
							if expr !in [ast.ComptimeType, ast.TypeNode] {
								c.error('invalid `\$if` condition, only types are allowed',
									expr.pos())
							}
						}
						return .unknown
					} else {
						c.error('invalid `\$if` condition', cond.pos)
					}
				}
				else {
					c.error('invalid `\$if` condition', cond.pos)
				}
			}
		}
		ast.Ident {
			cname := cond.name
			if cname in constants.valid_comptime_if_os {
				mut is_os_target_equal := true
				if !c.pref.output_cross_c {
					target_os := c.pref.os.str().to_lower()
					is_os_target_equal = cname == target_os
				}
				return if is_os_target_equal { .eval } else { .skip }
			} else if cname in constants.valid_comptime_if_compilers {
				return if pref.cc_from_string(cname) == c.pref.ccompiler_type {
					.eval
				} else {
					.skip
				}
			} else if cname in constants.valid_comptime_if_platforms {
				if cname == 'aarch64' {
					c.note('use `arm64` instead of `aarch64`', pos)
				}
				match cname {
					'amd64' { return if c.pref.arch == .amd64 { .eval } else { .skip } }
					'i386' { return if c.pref.arch == .i386 { .eval } else { .skip } }
					'aarch64' { return if c.pref.arch == .arm64 { .eval } else { .skip } }
					'arm64' { return if c.pref.arch == .arm64 { .eval } else { .skip } }
					'arm32' { return if c.pref.arch == .arm32 { .eval } else { .skip } }
					'rv64' { return if c.pref.arch == .rv64 { .eval } else { .skip } }
					'rv32' { return if c.pref.arch == .rv32 { .eval } else { .skip } }
					else { return .unknown }
				}
			} else if cname in constants.valid_comptime_if_cpu_features {
				return .unknown
			} else if cname in constants.valid_comptime_if_other {
				match cname {
					'apk' {
						return if c.pref.is_apk { .eval } else { .skip }
					}
					'js' {
						return if c.pref.backend.is_js() { .eval } else { .skip }
					}
					'debug' {
						return if c.pref.is_debug { .eval } else { .skip }
					}
					'prod' {
						return if c.pref.is_prod { .eval } else { .skip }
					}
					'profile' {
						return if c.pref.is_prof { .eval } else { .skip }
					}
					'test' {
						return if c.pref.is_test { .eval } else { .skip }
					}
					'musl' {
						return .unknown
					}
					'glibc' {
						return .unknown
					}
					'threads' {
						return if c.table.gostmts > 0 { .eval } else { .skip }
					}
					'prealloc' {
						return if c.pref.prealloc { .eval } else { .skip }
					}
					'no_bounds_checking' {
						return if cname in c.pref.compile_defines_all { .eval } else { .skip }
					}
					'freestanding' {
						return if c.pref.is_bare && !c.pref.output_cross_c { .eval } else { .skip }
					}
					'interpreter' {
						return if c.pref.backend == .interpret { .eval } else { .skip }
					}
					else {
						return .unknown
					}
				}
			} else if cname !in c.pref.compile_defines_all {
				if cname == 'linux_or_macos' {
					c.error('linux_or_macos is deprecated, use `\$if linux || macos {` instead',
						cond.pos)
					return .unknown
				}
				// `$if some_var {}`, or `[if user_defined_tag] fn abc(){}`
				typ := c.unwrap_generic(c.expr(cond))
				if cond.obj !in [ast.Var, ast.ConstField, ast.GlobalField] {
					if !c.inside_ct_attr {
						c.error('unknown var: `${cname}`', pos)
					}
					return .unknown
				}
				expr := c.find_obj_definition(cond.obj) or {
					c.error(err.msg(), cond.pos)
					return .unknown
				}
				if !c.check_types(typ, ast.bool_type) {
					type_name := c.table.type_to_str(typ)
					c.error('non-bool type `${type_name}` used as \$if condition', cond.pos)
				}
				// :)
				// until `v.eval` is stable, I can't think of a better way to do this
				return if (expr as ast.BoolLiteral).val { .eval } else { .skip }
			}
		}
		ast.ComptimeCall {
			if cond.is_pkgconfig {
				mut m := pkgconfig.main([cond.args_var]) or {
					c.error(err.msg(), cond.pos)
					return .skip
				}
				m.run() or { return .skip }
			}
			return .eval
		}
		ast.SelectorExpr {
			if c.check_comptime_is_field_selector(cond) {
				if c.check_comptime_is_field_selector_bool(cond) {
					ret_bool := c.get_comptime_selector_bool_field(cond.field_name)
					return if ret_bool { .eval } else { .skip }
				}
				c.error('unknown field `${cond.field_name}` from ${c.comptime_for_field_var}',
					cond.pos)
			}
			return .unknown
		}
		else {
			c.error('invalid `\$if` condition', pos)
		}
	}
	return .unknown
}

// get_comptime_selector_type retrieves the var.$(field.name) type when field_name is 'name' otherwise default_type is returned
[inline]
fn (mut c Checker) get_comptime_selector_type(node ast.ComptimeSelector, default_type ast.Type) ast.Type {
	if node.field_expr is ast.SelectorExpr
		&& c.check_comptime_is_field_selector(node.field_expr as ast.SelectorExpr)
		&& (node.field_expr as ast.SelectorExpr).field_name == 'name' {
		return c.unwrap_generic(c.comptime_fields_default_type)
	}
	return default_type
}

// check_comptime_is_field_selector checks if the SelectorExpr is related to $for variable
[inline]
fn (mut c Checker) check_comptime_is_field_selector(node ast.SelectorExpr) bool {
	if c.inside_comptime_for_field && node.expr is ast.Ident {
		return (node.expr as ast.Ident).name == c.comptime_for_field_var
	}
	return false
}

// check_comptime_is_field_selector_bool checks if the SelectorExpr is related to field.is_* boolean fields
[inline]
fn (mut c Checker) check_comptime_is_field_selector_bool(node ast.SelectorExpr) bool {
	if c.check_comptime_is_field_selector(node) {
		return node.field_name in ['is_mut', 'is_pub', 'is_shared', 'is_atomic', 'is_option',
			'is_array', 'is_map', 'is_chan', 'is_struct', 'is_alias', 'is_enum']
	}
	return false
}

// get_comptime_selector_bool_field evaluates the bool value for field.is_* fields
fn (mut c Checker) get_comptime_selector_bool_field(field_name string) bool {
	field := c.comptime_for_field_value
	field_typ := c.comptime_fields_default_type
	field_sym := c.table.sym(c.unwrap_generic(c.comptime_fields_default_type))

	match field_name {
		'is_pub' { return field.is_pub }
		'is_mut' { return field.is_mut }
		'is_shared' { return field_typ.has_flag(.shared_f) }
		'is_atomic' { return field_typ.has_flag(.atomic_f) }
		'is_option' { return field.typ.has_flag(.option) }
		'is_array' { return field_sym.kind in [.array, .array_fixed] }
		'is_map' { return field_sym.kind == .map }
		'is_chan' { return field_sym.kind == .chan }
		'is_struct' { return field_sym.kind == .struct_ }
		'is_alias' { return field_sym.kind == .alias }
		'is_enum' { return field_sym.kind == .enum_ }
		else { return false }
	}
}
