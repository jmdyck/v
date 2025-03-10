// Copyright (c) 2019-2022 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license that can be found in the LICENSE file.
module checker

import v.ast
import v.token

fn (mut c Checker) for_c_stmt(node ast.ForCStmt) {
	c.in_for_count++
	prev_loop_label := c.loop_label
	if node.has_init {
		c.stmt(node.init)
	}
	c.expr(node.cond)
	if node.has_inc {
		if node.inc is ast.AssignStmt {
			assign := node.inc

			if assign.op == .decl_assign {
				c.error('for loop post statement cannot be a variable declaration', assign.pos)
			}

			for right in assign.right {
				if right is ast.CallExpr {
					if right.or_block.stmts.len > 0 {
						c.error('options are not allowed in `for statement increment` (yet)',
							right.pos)
					}
				}
			}
		}
		c.stmt(node.inc)
	}
	c.check_loop_label(node.label, node.pos)
	c.stmts(node.stmts)
	c.loop_label = prev_loop_label
	c.in_for_count--
}

fn (mut c Checker) for_in_stmt(mut node ast.ForInStmt) {
	c.in_for_count++
	prev_loop_label := c.loop_label
	mut typ := c.expr(node.cond)
	if node.key_var.len > 0 && node.key_var != '_' {
		c.check_valid_snake_case(node.key_var, 'variable name', node.pos)
		if reserved_type_names_chk.matches(node.key_var) {
			c.error('invalid use of reserved type `${node.key_var}` as key name', node.pos)
		}
	}
	if node.val_var.len > 0 && node.val_var != '_' {
		c.check_valid_snake_case(node.val_var, 'variable name', node.pos)
		if reserved_type_names_chk.matches(node.val_var) {
			c.error('invalid use of reserved type `${node.val_var}` as value name', node.pos)
		}
	}
	if node.is_range {
		typ_idx := typ.idx()
		high_type := c.expr(node.high)
		high_type_idx := high_type.idx()
		if typ_idx in ast.integer_type_idxs && high_type_idx !in ast.integer_type_idxs
			&& high_type_idx != ast.void_type_idx {
			c.error('range types do not match', node.cond.pos())
		} else if typ_idx in ast.float_type_idxs || high_type_idx in ast.float_type_idxs {
			c.error('range type can not be float', node.cond.pos())
		} else if typ_idx == ast.bool_type_idx || high_type_idx == ast.bool_type_idx {
			c.error('range type can not be bool', node.cond.pos())
		} else if typ_idx == ast.string_type_idx || high_type_idx == ast.string_type_idx {
			c.error('range type can not be string', node.cond.pos())
		} else if typ_idx == ast.none_type_idx || high_type_idx == ast.none_type_idx {
			c.error('range type can not be none', node.cond.pos())
		} else if c.table.final_sym(typ).kind == .multi_return
			&& c.table.final_sym(high_type).kind == .multi_return {
			c.error('multi-returns cannot be used in ranges. A range is from a single value to a single higher value.',
				node.cond.pos())
		}
		if high_type in [ast.int_type, ast.int_literal_type] {
			node.val_type = typ
		} else {
			node.val_type = high_type
		}
		node.high_type = high_type
		node.scope.update_var_type(node.val_var, node.val_type)
	} else {
		mut sym := c.table.final_sym(typ)
		if sym.kind != .string {
			match mut node.cond {
				ast.PrefixExpr {
					node.val_is_ref = node.cond.op == .amp
				}
				ast.ComptimeSelector {
					comptime_typ := c.get_comptime_selector_type(node.cond, ast.void_type)
					if comptime_typ != ast.void_type {
						sym = c.table.final_sym(comptime_typ)
						typ = comptime_typ
					}
				}
				ast.Ident {
					match mut node.cond.info {
						ast.IdentVar {
							node.val_is_ref = !node.cond.is_mut() && node.cond.info.typ.is_ptr()
						}
						else {}
					}
				}
				else {}
			}
		} else if node.val_is_mut {
			c.error('string type is immutable, it cannot be changed', node.pos)
			return
		}
		if sym.kind == .struct_ {
			// iterators
			next_fn := sym.find_method_with_generic_parent('next') or {
				c.error('a struct must have a `next()` method to be an iterator', node.cond.pos())
				return
			}
			if !next_fn.return_type.has_flag(.option) {
				c.error('iterator method `next()` must return an Option', node.cond.pos())
			}
			return_sym := c.table.sym(next_fn.return_type)
			if return_sym.kind == .multi_return {
				c.error('iterator method `next()` must not return multiple values', node.cond.pos())
			}
			// the receiver
			if next_fn.params.len != 1 {
				c.error('iterator method `next()` must have 0 parameters', node.cond.pos())
			}
			mut val_type := next_fn.return_type.clear_flag(.option).clear_flag(.result)
			if node.val_is_mut {
				val_type = val_type.ref()
			}
			node.cond_type = typ
			node.kind = sym.kind
			node.val_type = val_type
			node.scope.update_var_type(node.val_var, val_type)
		} else if sym.kind == .any {
			node.cond_type = typ
			node.kind = sym.kind

			unwrapped_typ := c.unwrap_generic(typ)
			unwrapped_sym := c.table.sym(unwrapped_typ)

			if node.key_var.len > 0 {
				key_type := match unwrapped_sym.kind {
					.map { unwrapped_sym.map_info().key_type }
					else { ast.int_type }
				}
				node.key_type = key_type
				node.scope.update_var_type(node.key_var, key_type)
			}

			value_type := c.table.value_type(unwrapped_typ)
			node.scope.update_var_type(node.val_var, value_type)

			c.inside_for_in_any_cond = true
			c.for_in_any_val_type = value_type
		} else {
			if sym.kind == .map && !(node.key_var.len > 0 && node.val_var.len > 0) {
				c.error(
					'declare a key and a value variable when ranging a map: `for key, val in map {`\n' +
					'use `_` if you do not need the variable', node.pos)
			}
			if node.key_var.len > 0 {
				key_type := match sym.kind {
					.map { sym.map_info().key_type }
					else { ast.int_type }
				}
				node.key_type = key_type
				node.scope.update_var_type(node.key_var, key_type)
			}
			mut value_type := c.table.value_type(typ)
			if sym.kind == .string {
				value_type = ast.u8_type
			}
			if value_type == ast.void_type || typ.has_flag(.result) {
				if typ != ast.void_type {
					c.error('for in: cannot index `${c.table.type_to_str(typ)}`', node.cond.pos())
				}
			}
			if node.val_is_mut {
				value_type = value_type.ref()
				match mut node.cond {
					ast.Ident {
						if mut node.cond.obj is ast.Var {
							if !node.cond.obj.is_mut {
								c.error('`${node.cond.obj.name}` is immutable, it cannot be changed',
									node.cond.pos)
							}
						}
					}
					ast.ArrayInit {
						c.error('array literal is immutable, it cannot be changed', node.cond.pos)
					}
					ast.MapInit {
						c.error('map literal is immutable, it cannot be changed', node.cond.pos)
					}
					ast.SelectorExpr {
						if root_ident := node.cond.root_ident() {
							if root_ident.kind != .unresolved {
								if var := node.scope.find_var(root_ident.name) {
									if !var.is_mut {
										sym2 := c.table.sym(root_ident.obj.typ)
										c.error('field `${sym2.name}.${node.cond.field_name}` is immutable, it cannot be changed',
											node.cond.pos)
									}
								}
							}
						}
					}
					else {}
				}
			} else if node.val_is_ref {
				value_type = value_type.ref()
			}
			node.cond_type = typ
			node.kind = sym.kind
			node.val_type = value_type
			node.scope.update_var_type(node.val_var, value_type)
		}
	}
	c.check_loop_label(node.label, node.pos)
	c.stmts(node.stmts)
	c.loop_label = prev_loop_label
	c.inside_for_in_any_cond = false
	c.for_in_any_val_type = 0
	c.in_for_count--
}

fn (mut c Checker) for_stmt(mut node ast.ForStmt) {
	c.in_for_count++
	prev_loop_label := c.loop_label
	c.expected_type = ast.bool_type
	if node.cond !is ast.EmptyExpr {
		typ := c.expr(node.cond)
		if !node.is_inf && typ.idx() != ast.bool_type_idx && !c.pref.translated
			&& !c.file.is_translated {
			c.error('non-bool used as for condition', node.pos)
		}
	}
	if mut node.cond is ast.InfixExpr {
		if node.cond.op == .key_is {
			if node.cond.right is ast.TypeNode && node.cond.left in [ast.Ident, ast.SelectorExpr] {
				if c.table.type_kind(node.cond.left_type) in [.sum_type, .interface_] {
					c.smartcast(node.cond.left, node.cond.left_type, node.cond.right_type, mut
						node.scope)
				}
			}
		}
	}
	// TODO: update loop var type
	// how does this work currenly?
	c.check_loop_label(node.label, node.pos)
	c.stmts(node.stmts)
	c.loop_label = prev_loop_label
	c.in_for_count--
	if c.smartcast_mut_pos != token.Pos{} {
		c.smartcast_mut_pos = token.Pos{}
	}
}
