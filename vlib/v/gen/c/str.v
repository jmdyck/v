// Copyright (c) 2019-2022 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license that can be found in the LICENSE file.
module c

import v.ast
import v.util

fn (mut g Gen) string_literal(node ast.StringLiteral) {
	escaped_val := cescape_nonascii(util.smart_quote(node.val, node.is_raw))
	if node.language == .c {
		g.write('"${escaped_val}"')
	} else {
		g.write('_SLIT("${escaped_val}")')
	}
}

// optimize string interpolation in string builders:
// `sb.writeln('a=$a')` =>
// `sb.writeln('a='); sb.writeln(a.str())`
fn (mut g Gen) string_inter_literal_sb_optimized(call_expr ast.CallExpr) {
	node := call_expr.args[0].expr as ast.StringInterLiteral
	g.writeln('// sb inter opt')
	is_nl := call_expr.name == 'writeln'
	for i, val in node.vals {
		escaped_val := cescape_nonascii(util.smart_quote(val, false))
		g.write('strings__Builder_write_string(&')
		g.expr(call_expr.left)
		g.write(', _SLIT("')
		g.write(escaped_val)
		g.writeln('"));')
		if i >= node.exprs.len {
			break
		}
		if is_nl && i == node.exprs.len - 1 {
			g.write('strings__Builder_writeln(&')
		} else {
			g.write('strings__Builder_write_string(&')
		}
		g.expr(call_expr.left)
		g.write(', ')
		typ := node.expr_types[i]
		g.write(g.typ(typ))
		g.write('_str(')
		sym := g.table.sym(typ)
		if sym.kind != .function {
			g.expr(node.exprs[i])
		}
		g.writeln('));')
	}
	g.writeln('')
	return
}

fn (mut g Gen) gen_expr_to_string(expr ast.Expr, etype ast.Type) {
	old_inside_opt_or_res := g.inside_opt_or_res
	g.inside_opt_or_res = true
	defer {
		g.inside_opt_or_res = old_inside_opt_or_res
	}
	is_shared := etype.has_flag(.shared_f)
	mut typ := etype
	if is_shared {
		typ = typ.clear_flag(.shared_f).set_nr_muls(0)
	}
	mut sym := g.table.sym(typ)
	// when type is non-option alias and doesn't has `str()`, print the aliased value
	if mut sym.info is ast.Alias && !sym.has_method('str') && !etype.has_flag(.option) {
		parent_sym := g.table.sym(sym.info.parent_type)
		if parent_sym.has_method('str') {
			typ = sym.info.parent_type
			sym = parent_sym
		}
	}
	sym_has_str_method, str_method_expects_ptr, _ := sym.str_method_info()
	if typ.has_flag(.variadic) {
		str_fn_name := g.get_str_fn(typ)
		g.write('${str_fn_name}(')
		g.expr(expr)
		g.write(')')
	} else if typ == ast.string_type {
		if etype.is_ptr() {
			g.write('*')
		}
		g.expr(expr)
	} else if typ == ast.bool_type {
		g.expr(expr)
		g.write(' ? _SLIT("true") : _SLIT("false")')
	} else if sym.kind == .none_ || typ == ast.void_type.set_flag(.option) {
		g.write('_SLIT("<none>")')
	} else if sym.kind == .enum_ {
		if expr !is ast.EnumVal {
			str_fn_name := g.get_str_fn(typ)
			g.write('${str_fn_name}(')
			if typ.nr_muls() > 0 {
				g.write('*'.repeat(typ.nr_muls()))
			}
			g.enum_expr(expr)
			g.write(')')
		} else {
			g.write('_SLIT("')
			g.enum_expr(expr)
			g.write('")')
		}
	} else if sym_has_str_method
		|| sym.kind in [.array, .array_fixed, .map, .struct_, .multi_return, .sum_type, .interface_] {
		unwrap_option := expr is ast.Ident && (expr as ast.Ident).or_expr.kind == .propagate_option
		exp_typ := if unwrap_option { typ.clear_flag(.option) } else { typ }
		is_ptr := exp_typ.is_ptr()
		is_var_mut := expr.is_auto_deref_var()
		str_fn_name := g.get_str_fn(exp_typ)
		if is_ptr && !is_var_mut {
			ref_str := '&'.repeat(typ.nr_muls())
			g.write('str_intp(1, _MOV((StrIntpData[]){{_SLIT("${ref_str}"), ${si_s_code} ,{.d_s = isnil(')
			if is_ptr && typ.has_flag(.option) {
				g.write('*(${g.base_type(exp_typ)}*)&')
				g.expr(expr)
				g.write('.data')
				g.write(') ? _SLIT("Option(&nil)") : ')
			} else {
				g.expr(expr)
				g.write(') ? _SLIT("nil") : ')
			}
		}
		g.write('${str_fn_name}(')
		if str_method_expects_ptr && !is_ptr {
			g.write('&')
		} else if is_ptr && typ.has_flag(.option) {
			g.write('*(${g.typ(typ.set_nr_muls(0))}*)&')
		} else if !str_method_expects_ptr && !is_shared && (is_ptr || is_var_mut) {
			g.write('*'.repeat(typ.nr_muls()))
		}
		if expr is ast.ArrayInit {
			if expr.is_fixed {
				s := g.typ(expr.typ)
				if !expr.has_index {
					g.write('(${s})')
				}
			}
		}
		if unwrap_option {
			g.expr(expr)
		} else {
			g.expr_with_cast(expr, typ, typ)
		}

		if is_shared {
			g.write('->val')
		}
		g.write(')')
		if is_ptr && !is_var_mut {
			g.write('}}}))')
		}
	} else {
		is_ptr := typ.is_ptr()
		is_var_mut := expr.is_auto_deref_var()
		str_fn_name := g.get_str_fn(typ)
		g.write('${str_fn_name}(')
		if sym.kind != .function {
			if str_method_expects_ptr && !is_ptr {
				g.write('&')
			} else if (!str_method_expects_ptr && is_ptr && !is_shared) || is_var_mut {
				g.write('*')
			}
			g.expr_with_cast(expr, typ, typ)
		} else {
			g.expr_with_cast(expr, typ, typ)
		}
		g.write(')')
	}
}
