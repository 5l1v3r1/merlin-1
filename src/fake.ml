(* {{{ COPYING *(

  This file is part of Merlin, an helper for ocaml editors

  Copyright (C) 2013  Frédéric Bour  <frederic.bour(_)lakaban.net>
                      Thomas Refis  <refis.thomas(_)gmail.com>
                      Simon Castellan  <simon.castellan(_)iuwt.fr>

  Permission is hereby granted, free of charge, to any person obtaining a
  copy of this software and associated documentation files (the "Software"),
  to deal in the Software without restriction, including without limitation the
  rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
  sell copies of the Software, and to permit persons to whom the Software is
  furnished to do so, subject to the following conditions:

  The above copyright notice and this permission notice shall be included in
  all copies or substantial portions of the Software.

  The Software is provided "as is", without warranty of any kind, express or
  implied, including but not limited to the warranties of merchantability,
  fitness for a particular purpose and noninfringement. In no event shall
  the authors or copyright holders be liable for any claim, damages or other
  liability, whether in an action of contract, tort or otherwise, arising
  from, out of or in connection with the software or the use or other dealings
  in the Software.

)* }}} *)

open Parsetree
open Std

let default_loc = function
  | None -> Location.none
  | Some loc -> loc

let mkoptloc opt x =
  match opt with
  | None -> Location.mknoloc x
  | Some l -> Location.mkloc x l

let app a b =
  let pexp_loc = { b.pexp_loc with Location.loc_ghost = true } in
  { pexp_desc = Pexp_apply (a, ["", b]) ; pexp_loc }

let pat_app f (pat,expr) = pat, app f expr

let prim_ident prim = Longident.parse ("_." ^ prim)
let prim prim = {
  pexp_desc = Pexp_ident (Location.mknoloc (prim_ident prim));
  pexp_loc = Location.none
}

let any_val' = prim "Any.val'"


(* Helpers; extend as needed *)
module Ast = struct
  type type_scheme =
    | Var   of string
    | Arrow of Asttypes.label * type_scheme * type_scheme
    | Tuple of type_scheme list
    | Named of type_scheme list * string
    | Core_type of core_type

  and expr =
    | Fun   of (string * bool) list * expr
    | App   of expr * expr
    | Ident of string
    | AnyVal (* wild card ident *)

  and binding = {
    ident   : string ;
    typesig : type_scheme ;
    body    : expr ;
  }

  and top_item =
    | Binding of binding
    | Module of string * top_item list

  let sub_of_simple_variants lst =
    let variants = List.map lst ~f:(fun s -> Rtag (s, true, [])) in
    let ptyp_desc = Ptyp_variant (variants, true, Some []) in
    Core_type { ptyp_desc ; ptyp_loc = Location.symbol_gloc () }

  let freshvars  = Stream.from (fun i -> Some (Printf.sprintf "\x00_%d" i))
  let new_var () = Stream.next freshvars
end

open Ast

let unit_ty = Named ([],"unit")
let bool_ty = Named ([],"bool")

let rec translate_ts ?ghost_loc = function
  | Var ident ->
    { ptyp_desc = Ptyp_var ident ; ptyp_loc = default_loc ghost_loc }
  | Arrow (label, a, b) ->
    let a = translate_ts ?ghost_loc a in
    let b = translate_ts ?ghost_loc b in
    { ptyp_desc = Ptyp_arrow(label, a, b) ; ptyp_loc = default_loc ghost_loc }
  | Tuple lst ->
    let lst = List.map lst ~f:(translate_ts ?ghost_loc) in
    { ptyp_desc = Ptyp_tuple lst ; ptyp_loc = default_loc ghost_loc }
  | Named (params, id) ->
    let id = Longident.parse id in
    let params = List.map (translate_ts ?ghost_loc) params in
    {
      ptyp_desc = Ptyp_constr (mkoptloc ghost_loc id, params) ;
      ptyp_loc = default_loc ghost_loc ;
    }
  | Core_type ct -> ct

and translate_expr ?ghost_loc : Ast.expr -> _ = function
  | Fun (simple_patterns, body) ->
    List.fold_right simple_patterns ~init:(translate_expr ?ghost_loc body) ~f:(
      fun (simple_pattern, is_label) body ->
        let patt = {
          ppat_desc = Ppat_var (mkoptloc ghost_loc simple_pattern) ;
          ppat_loc = default_loc ghost_loc ;
        }
        in
        let label = if is_label then simple_pattern else "" in
        {
          pexp_desc = Pexp_function (label, None, [patt, body]) ;
          pexp_loc = default_loc ghost_loc ;
        }
    )
  | App (f, x) ->
    app (translate_expr ?ghost_loc f) (translate_expr ?ghost_loc x)
  | Ident i -> {
      pexp_desc = Pexp_ident (mkoptloc ghost_loc (Longident.parse i)) ;
      pexp_loc = default_loc ghost_loc ;
    }
  | AnyVal -> any_val'


let sig_of_binding ?ghost_loc { ident; typesig; body = _ } =
  let pval_ty = {
    pval_type = translate_ts ?ghost_loc typesig ;
    pval_prim = [] ;
    pval_loc  = default_loc ghost_loc ;
  } in
  let psig_desc = Psig_value (mkoptloc ghost_loc ident, pval_ty) in
  { psig_desc ; psig_loc = default_loc ghost_loc }

let str_of_binding ?ghost_loc { ident; typesig; body } =
  let pat = {
    ppat_desc = Ppat_var (mkoptloc ghost_loc ident) ;
    ppat_loc = default_loc ghost_loc ;
  }
  in
  let typesig_opt = Some (translate_ts ?ghost_loc typesig) in
  let body = translate_expr ?ghost_loc body in
  let pexp = {
    pexp_desc = Pexp_constraint (body, typesig_opt, None) ;
    pexp_loc = default_loc ghost_loc ;
  }
  in
  {
    pstr_desc = Pstr_value (Asttypes.Nonrecursive, [(pat, pexp)]) ;
    pstr_loc = default_loc ghost_loc ;
  }

let rec str_of_top_lvl ?ghost_loc = function
  | Binding b -> str_of_binding ?ghost_loc b
  | Module (name, m) ->
    let loc = { Location. txt = name ; loc = default_loc ghost_loc } in
    let mod_expr = {
      pmod_loc  = loc.Location.loc;
      pmod_desc = Pmod_structure (List.map str_of_top_lvl m) ;
    }
    in
    { pstr_desc = Pstr_module (loc, mod_expr) ; pstr_loc  = default_loc ghost_loc }

let rec sig_of_top_lvl ?ghost_loc = function
  | Binding b -> sig_of_binding ?ghost_loc b
  | Module (name, m) ->
    let loc = { Location. txt = name ; loc = default_loc ghost_loc } in
    let mod_type = {
      pmty_loc  = loc.Location.loc;
      pmty_desc = Pmty_signature (List.map sig_of_top_lvl m) ;
    }
    in
    { psig_desc = Psig_module (loc, mod_type) ; psig_loc  = default_loc ghost_loc }

(* Lwt extension *)
module Lwt = struct
  let un_lwt = prim "Lwt.un_lwt"
  let to_lwt = prim "Lwt.to_lwt"
  let in_lwt = prim "Lwt.in_lwt"
  let unit_lwt = prim "Lwt.unit_lwt"
  let un_stream = prim "Lwt.un_stream"
  let finally' = prim "Lwt.finally'"
  let raise_lwt' = prim_ident "Lwt.raise_lwt'"
end

(* Js extension *)
module Js = struct
  let un_js     = prim "Js.un_js"
  let un_meth   = prim "Js.un_meth"
  let un_constr = prim "Js.un_constr"
  let un_prop   = prim "Js.un_prop"
end

(* OUnit extension *)
module OUnit = struct
  let fresh_test_module_ident =
    let counter = ref 0 in
    fun () ->
      incr counter;
      ("_TEST_" ^ string_of_int !counter)

  let force_bool = prim "OUnit.force_bool"
  let force_unit = prim "OUnit.force_unit"
  let force_unit_arrow_unit = prim "OUnit.force_unit_arrow_unit"
  let force_indexed = prim "OUnit.force_indexed"
end

(* tools used in the next few modules *)
let format_params ~f =
  List.map ~f:(function None -> f "_" | Some id -> f id.Location.txt)

let mk_fun ~args =
  Fun (List.map (fun s -> (s, false)) args, App (Ident "Obj.magic", AnyVal))

let mk_labeled_fun ~args = Fun (args, App (Ident "Obj.magic", AnyVal))

type tydecl = string Location.loc * Parsetree.type_declaration

(*module type Type_conv_intf = sig
  val bindings : tydecl -> Ast.binding list
end*)

(** Some extensions (sexp, cow) follow a very simple generation pattern *)
module type Simple_conv_intf = sig
  val t : Ast.type_scheme
  val name : string
end

module Make_simple (Conv : Simple_conv_intf) = struct
  let mk_arrow x y = Arrow ("", x, y)

  let named params ty = Named (params, ty)

  let conv_of_sig params ty =
    let params = format_params ~f:(fun v -> Var v) params in
    List.fold_right ~f:(fun var acc -> mk_arrow (mk_arrow var Conv.t) acc) params
      ~init:(mk_arrow (named params ty) Conv.t)

  let of_conv_sig params ty =
    let params = format_params ~f:(fun v -> Var v) params in
    List.fold_right ~f:(fun var acc -> mk_arrow (mk_arrow Conv.t var) acc) params
      ~init:(mk_arrow Conv.t (Named (params, ty)))

  let conv_of_ (located_name, type_infos) =
    let ty = located_name.Location.txt in
    let args =
      let f x = Conv.name ^ "_of_" ^ x in
      format_params ~f type_infos.ptype_params
    in
    Binding {
      ident = Conv.name ^ "_of_" ^ ty ;
      typesig = conv_of_sig type_infos.ptype_params ty;
      body = mk_fun ~args ;
    }

  let _of_conv (located_name, type_infos) =
    let ty = located_name.Location.txt in
    let args =
      let f x = x ^ "_of_" ^ Conv.name in
      format_params ~f type_infos.ptype_params
    in
    Binding {
      ident = ty ^ "_of_" ^ Conv.name ;
      typesig = of_conv_sig type_infos.ptype_params ty;
      body = mk_fun ~args ;
    }

  let bindings ty = [ conv_of_ ty ; _of_conv ty ]
end

module Sexp = Make_simple(struct
  let t = Named ([], "Sexplib.Sexp.t")
  let name = "sexp"
end)

(* the Cow generators are parametrized by the extension name *)
let cow_supported_extension ext = List.mem ext ["json"; "xml"; "html";]
module Make_cow (Ext : sig val name : string end) =
  Make_simple(struct
    let t = Named ([], "Cow." ^(String.capitalize Ext.name)^ ".t")
    let name = Ext.name
  end)

module Binprot = struct

  let binding ~prefix ?(suffix="") ~typesig ty =
    let (located_name, ty_infos) = ty in
    let tyname = located_name.Location.txt in
    let args = format_params ~f:(fun x -> prefix ^ x ^ suffix) ty_infos.ptype_params in
    Binding {
      ident = prefix ^ tyname ^ suffix;
      typesig = typesig ty ;
      body = mk_fun ~args ;
    }

  module Sizer = struct
    let int = Named ([], "int")

    let typesig (name, ty_infos) =
      let params = format_params ~f:(fun x -> x) ty_infos.ptype_params in
      List.fold_right ~f:(fun v acc -> Arrow ("", Arrow ("", Var v, int), acc)) params
        ~init:(Arrow ("", Named (List.map (fun x -> Var x) params, name.Location.txt), int))

    let prefix = "bin_size_"

    let binding ty = binding ~prefix ~typesig ty
  end

  module Write = struct
    let writer t = Named ([t], "Bin_prot.Write.writer")

    let typesig (name, ty_infos) =
      let params = format_params ~f:(fun x -> x) ty_infos.ptype_params in
      let t = Named (List.map (fun x -> Var x) params, name.Location.txt) in
      let init = writer t in
      let make_var str = writer (Var str) in
      List.fold_right ~init ~f:(fun v acc -> Arrow ("", make_var v, acc)) params

    let prefix = "bin_write_"

    let binding ty = binding ~prefix ~typesig ty
  end

  (*module Write_ = struct
    let typesig (name, ty_infos) =
      let params = format_params ~f:(fun x -> x) ty_infos.ptype_params in
      let init =
        Arrow ("", Named ([], "Bin_prot.Unsafe_common.sptr"),
        Arrow ("", Named ([], "Bin_prot.Unsafe_common.eptr"),
        Arrow ("", Named (List.map (fun x -> Var x) params, name.Location.txt),
        Named ([], "Bin_prot.Unsafe_common.sptr"))))
      in
      let make_var str =
        Arrow ("", Named ([], "Bin_prot.Unsafe_common.sptr"),
        Arrow ("", Named ([], "Bin_prot.Unsafe_common.eptr"),
        Arrow ("", Var str,
        Named ([], "Bin_prot.Unsafe_common.sptr"))))
      in
      List.fold_right ~f:(fun v acc -> Arrow ("", make_var v, acc)) params ~init

    let prefix = "bin_write_"
    let suffix = "_"

    let binding ty = binding ~prefix ~suffix ~typesig ty
  end*)

  module Writer = struct
    let typesig (name, ty_infos) =
      let params = format_params ~f:(fun x -> Var x) ty_infos.ptype_params in
      List.fold_right params
        ~init:(Named ([Named (params, name.Location.txt)], "Bin_prot.Type_class.writer"))
        ~f:(fun param acc -> Arrow ("", Named ([param], "Bin_prot.Type_class.writer"), acc))

    let prefix = "bin_writer_"

    let binding ty = binding ~prefix ~typesig ty
  end

  module Read = struct
    let reader t = Named ([t], "Bin_prot.Read.reader")
    let typesig (name, ty_infos) =
      let params = format_params ~f:(fun x -> x) ty_infos.ptype_params in
      let init = reader
        (Named (List.map (fun x -> Var x) params, name.Location.txt))
      in
      let make_var str = reader (Var str) in
      List.fold_right ~f:(fun v acc -> Arrow ("", make_var v, acc)) ~init params

    let prefix = "bin_read_"

    let binding ty = binding ~prefix ~typesig ty
  end

  (*module Read_ = struct
    let typesig (name, ty_infos) =
      let params = format_params ~f:(fun x -> x) ty_infos.ptype_params in
      let init =
        Arrow ("", Named ([], "Bin_prot.Unsafe_common.sptr_ptr"),
        Arrow ("", Named ([], "Bin_prot.Unsafe_common.eptr"),
        Named (List.map (fun x -> Var x) params, name.Location.txt)))
      in
      let make_var str =
        Arrow ("", Named ([], "Bin_prot.Unsafe_common.sptr_ptr"),
        Arrow ("", Named ([], "Bin_prot.Unsafe_common.eptr"),
        Var str))
      in
      List.fold_right ~f:(fun v acc -> Arrow ("", make_var v, acc)) params ~init

    let prefix = "bin_read_"
    let suffix = "_"

    let binding ty = binding ~prefix ~suffix ~typesig ty
  end*)

  module Read__ = struct
    let typesig (name, ty_infos) =
      let params = format_params ~f:(fun x -> x) ty_infos.ptype_params in
      let res = Named (List.map (fun x -> Var x) params, name.Location.txt) in
      let init = Read.reader (Arrow ("", Named ([], "int"), res)) in
      let make_var str = Read.reader (Var str) in
      List.fold_right ~f:(fun v acc -> Arrow ("", make_var v, acc)) ~init params

    let prefix = "__bin_read_"
    let suffix = "__"

    let binding ty = binding ~prefix ~suffix ~typesig ty
  end

  module Reader = struct
    let typesig (name, ty_infos) =
      let params = format_params ~f:(fun x -> Var x) ty_infos.ptype_params in
      List.fold_right params
        ~init:(Named ([Named (params, name.Location.txt)], "Bin_prot.Type_class.reader"))
        ~f:(fun param acc -> Arrow ("", Named ([param], "Bin_prot.Type_class.reader"), acc))

    let prefix = "bin_reader_"

    let binding ty = binding ~prefix ~typesig ty
  end

  module Type_class = struct
    let typesig (name, ty_infos) =
      let params = format_params ~f:(fun x -> Var x) ty_infos.ptype_params in
      List.fold_right params
        ~init:(Named ([Named (params, name.Location.txt)], "Bin_prot.Type_class.t"))
        ~f:(fun param acc -> Arrow ("", Named ([param], "Bin_prot.Type_class.t"), acc))

    let prefix = "bin_"

    let binding ty = binding ~prefix ~typesig ty
  end
end

(* TODO: factorize [Variants] and [Fields] *)
module Variants = struct
  let mk_cstr_typesig ~self args res_opt =
    let r = Option.value_map res_opt ~default:self ~f:(fun x -> Core_type x) in
    List.fold_right args ~init:r ~f:(fun arg ret_ty ->
      Arrow ("", Core_type arg, ret_ty)
    )

  let constructors ~self cstrs =
    List.map cstrs ~f:(fun ({ Location.txt = name }, args, res_opt, loc) ->
      let typesig = mk_cstr_typesig ~self args res_opt in
      Binding { ident = String.lowercase name ; typesig ; body = AnyVal }
    )

  let mk_module ~self cstrs =
    let cstrs_dot_t =
      List.map cstrs ~f:(fun ({ Location.txt = name }, args, res_opt, loc) ->
        let t = Named ([mk_cstr_typesig ~self args res_opt], "Variant.t") in
        { ident = String.lowercase name ; typesig = t ; body = AnyVal }
      )
    in

    let fold =
      let typesig =
        let a = new_var () in
        let init_ty, arrows =
          List.fold_right cstrs_dot_t ~init:(a, Var a) ~f:(
            fun cstr (fun_res, acc) ->
              let param = new_var () in
              let f =
                Arrow ("", Var param, Arrow ("", cstr.typesig, Var fun_res))
              in
              (param, Arrow (cstr.ident, f, acc))
          )
        in
        Arrow ("init", Var init_ty, arrows)
      in
      let body =
        mk_labeled_fun (List.map cstrs ~f:(fun (l,_,_,_) -> l.Location.txt,true))
      in
      let body = Fun (["init", true], body) in
      Binding { ident = "fold" ; typesig ; body }
    in

    let iter =
      let typesig =
        List.fold_right cstrs_dot_t ~init:unit_ty ~f:(fun cstr acc ->
          Arrow (cstr.ident, Arrow ("", cstr.typesig, unit_ty), acc)
        )
      in
      let body =
        let args = List.map cstrs_dot_t ~f:(fun b -> b.ident, true) in
        Fun (args, AnyVal)
      in
      Binding { ident = "iter" ; typesig ; body }
    in

    let map =
      let typesig =
        let ret_ty = Var (new_var ()) in
        List.fold_right2 cstrs_dot_t cstrs ~init:ret_ty ~f:(
          fun cstr (_, args, _res_opt, _) acc ->
            let tmp =
              List.fold_right args ~init:ret_ty
                ~f:(fun arg acc -> Arrow ("", Core_type arg, acc))
            in
            Arrow (cstr.ident, Arrow ("", cstr.typesig, tmp), acc)
        )
      in
      let typesig = Arrow ("", self, typesig) in
      let body =
        let args = List.map cstrs_dot_t ~f:(fun b -> b.ident, true) in
        Fun ((new_var (), false) :: args, AnyVal)
      in
      Binding { ident = "map" ; typesig ; body }
    in

    let descriptions =
      let (!) x = Named ([], x) in
      Binding {
        ident = "descriptions" ;
        typesig = Named ([Tuple [ !"string" ; !"int" ]], "list") ;
        body = AnyVal ;
      }
    in

    Module ("Variants", List.map cstrs_dot_t ~f:(fun b -> Binding b) @ [ 
      fold ; iter ; map ; descriptions
    ])

  let top_lvl ({ Location.txt = name },ty) =
    let params =
      List.map ty.ptype_params ~f:(
        function
        | None -> Var "_"
        | Some s -> Var (s.Location.txt)
      )
    in
    let self = Named (params, name) in
    match ty.ptype_kind with
    | Parsetree.Ptype_variant cstrs ->
      constructors ~self cstrs @ [mk_module ~self cstrs]
    | _ -> []
end

module Fields = struct
  let gen_field self ({ Location.txt = name }, mut, ty, _) : top_item list =
    (* Remove higher-rank quantifiers *)
    let ty = match ty.ptyp_desc with Ptyp_poly (_,ty) -> ty | _ -> ty in
    let ty = Core_type ty in
    let accessor = Arrow ("", self, ty) in
    let fields = [Binding { ident = name; typesig = accessor; body = AnyVal }] in
    match mut with
    | Asttypes.Immutable -> fields
    | Asttypes.Mutable ->
      let typesig = Arrow ("", self, Arrow ("", ty, unit_ty)) in
      (Binding { ident = "set_" ^ name; typesig ; body = AnyVal }) :: fields

  let make_fields_module ~self fields : top_item =
    let names =
      let typesig = Named ([Named ([], "string")], "list") in
      Binding { ident = "names" ; typesig ; body = AnyVal }
    in

    let fields_dot_t =
      let perms = sub_of_simple_variants [ "Read" ; "Set_and_create" ] in
      List.map fields ~f:(fun ({ Location.txt = name }, _, ty, _) ->
        let ty = match ty.ptyp_desc with Ptyp_poly (_,ty) -> ty | _ -> ty in
        let t = Named ([ perms ; self ; Core_type ty ], "Field.t_with_perm") in
        { ident = name ; typesig = t ; body = AnyVal }
      )
    in

    (* Helper, used in the next few functions *)
    let body =
      mk_labeled_fun (List.map fields ~f:(fun (l,_,_,_) -> l.Location.txt,true))
    in

(*
    That is so ugly.

    val make_creator :
      x:(([< `Read | `Set_and_create ], t, int) Field.t_with_perm -> 'a -> ('b -> int) * 'c) ->
      y:(([< `Read | `Set_and_create ], t, float ref) Field.t_with_perm -> 'c -> ('b -> float ref) * 'd) ->
      'a -> ('b -> t) * 'd
*)
    let make_creator =
      let acc_ret_ty = Var (new_var ()) in
      let ios, first_input =
        List.fold_right fields ~init:([], acc_ret_ty) ~f:(fun f (lst, acc) ->
          let x = Var (new_var ()) in
          (x, acc) :: lst, x
        )
      in
      let creator_input = Var (new_var ()) in
      let init =
        let creator = Arrow ("", creator_input, self) in
        Arrow ("", first_input, Tuple [ creator ; acc_ret_ty ])
      in
      let lst = 
        List.map2 fields fields_dot_t ~f:(fun (name, _, ty, _) fdt ->
          (name.Location.txt, ty, fdt)
        )
      in
      let typesig =
        List.fold_right2 lst ios ~init ~f:(fun (name, ty, f_dot_t) (i, o) acc ->
          let field_creator = Arrow ("", creator_input, Core_type ty) in
          Arrow (
            name,
            Arrow ("", f_dot_t.typesig, Arrow ("", i, Tuple [ field_creator ; o ])),
            acc
          )
        )
      in
      Binding { ident = "make_creator" ; typesig ; body }
    in

    let create =
      let typesig =
        List.fold_right fields ~init:self ~f:(fun (name, _, t, _) acc ->
          Arrow (name.Location.txt, Core_type t, acc)
        )
      in
      Binding { ident = "create" ; typesig ; body }
    in

    let linear_pass ?result ~name ret_ty =
      let init =
        match result with
        | None -> ret_ty
        | Some ty -> ty
      in
      let typesig =
        List.fold_right fields_dot_t ~init ~f:(fun field acc_ty ->
          Arrow (field.ident, Arrow ("", field.typesig, ret_ty), acc_ty)
        )
      in
      Binding { ident = name ; typesig ; body }
    in

    let iter = linear_pass ~name:"iter" unit_ty in
    let forall = linear_pass ~name:"for_all" bool_ty in
    let exists = linear_pass ~name:"exists" bool_ty in
    let to_list =
      let ty_var = Var (new_var ()) in
      linear_pass ~result:(Named ([ty_var], "list")) ~name:"to_list" ty_var
    in

    let fold =
      let typesig =
        let a = new_var () in
        let init_ty, arrows =
          List.fold_right fields_dot_t ~init:(a, Var a) ~f:(
            fun field (fun_res, acc) ->
              let param = new_var () in
              let f =
                Arrow ("", Var param, Arrow ("", field.typesig, Var fun_res))
              in
              (param, Arrow (field.ident, f, acc))
          )
        in
        Arrow ("init", Var init_ty, arrows)
      in
      let body = Fun (["init", true], body) in
      Binding { ident = "fold" ; typesig ; body }
    in

    let map =
      let typesig =
        List.fold_right2 fields_dot_t fields ~init:self ~f:(
          fun field_t field acc_ty ->
            let (_, _, ty, _) = field in
            let ty = match ty.ptyp_desc with Ptyp_poly (_,ty) -> ty | _ -> ty in
            Arrow (field_t.ident,
              Arrow ("", field_t.typesig, Core_type ty), acc_ty
            )
        )
      in
      Binding { ident = "map" ; typesig ; body }
    in

    let map_poly =
      let var = Var (new_var ()) in
      let perms = sub_of_simple_variants [ "Read" ; "Set_and_create" ] in
      let user = Named ([ perms ; self ; var ], "Field.user") in
      let typesig = Arrow ("", user, Named ([var], "list")) in
      Binding { ident = "map_poly" ; typesig ; body = AnyVal }
    in

    Module (
      "Fields",
      names :: List.map fields_dot_t ~f:(fun x -> Binding x) @ [
        make_creator ; create ; iter ; map ; fold ; map_poly ; forall ; exists ;
        to_list ; Module ("Direct", [ iter ; fold ])
      ]
    )

  let top_lvl ({ Location.txt = name },ty) =
    let params =
      List.map ty.ptype_params ~f:(
        function
        | None -> Var "_"
        | Some s -> Var (s.Location.txt)
      )
    in
    let self = Named (params, name) in
    match ty.ptype_kind with
    | Parsetree.Ptype_record lst ->
      List.concat_map ~f:(gen_field self) lst @ [make_fields_module ~self lst]
    | _ -> []

end

module Enumerate = struct
  let top_lvl ({ Location.txt = name },ty) =
    let ident = if name = "t" then "all" else "all_of_" ^ name in
    let typesig =
      let params =
        List.map ty.ptype_params ~f:(function
          | None -> Var "_"
          | Some { Location.txt } -> Var txt
        )
      in
      let param =
        Named (params, name)
      in
      List.fold_right params ~init:(Named ([param], "list")) ~f:(fun var acc ->
        Arrow ("", var, acc)
      )
    in
    Binding { ident ; typesig ; body = AnyVal }
end

module Compare = struct
  let mk_simpl t = Arrow ("", t, Arrow ("", t, Named ([], "int")))

  let bindings ~kind ({ Location.txt = name },ty) =
    let params = List.map
        (function None -> Var "_" | Some s -> Var (s.Location.txt))
        ty.ptype_params
    in
    let self = Named (params, name) in
    let cmp = {
      ident = "compare_" ^ name;
      typesig =
        List.fold_left params ~init:(mk_simpl self) ~f:(fun t param ->
          Arrow ("", mk_simpl param, t)
        );
      body = AnyVal
    } in
    match kind with
    | `Def when name = "t" -> [ Binding {cmp with ident = "compare"}; Binding cmp]
    | `Sig when name = "t" -> [Binding {cmp with ident = "compare"}]
    | _ -> [Binding cmp]

end

module TypeWith = struct
  type generator = string

  let generate_bindings ~kind ~ty = function
    | "sexp" -> List.concat_map ~f:Sexp.bindings ty
    | "sexp_of" -> List.map ~f:Sexp.conv_of_ ty
    | "of_sexp" -> List.map ~f:Sexp._of_conv ty

    | "bin_write" ->
      let open Binprot in
      List.concat_map ~f:(fun ty ->
          [ Sizer.binding ty ;
            Write.binding ty ;
            Writer.binding ty ]
      ) ty

    | "bin_read" ->
      let open Binprot in
      List.concat_map ~f:(fun ty ->
        [ Read.binding ty ;
          Read__.binding ty ;
          Reader.binding ty ]
      ) ty

    | "bin_io" ->
      let open Binprot in
      List.concat_map ~f:(fun ty ->
        [
          Sizer.binding ty ;
          Write.binding ty ;
          (*Write_.binding ty ;*)
          Writer.binding ty ;
          Read.binding ty ;
          (*Read_.binding ty ;*)
          Read__.binding ty ;
          Reader.binding ty ;
          Type_class.binding ty ;
        ]
      ) ty

    | "fields" ->
      List.concat_map ~f:Fields.top_lvl ty

    | "variants" ->
      List.concat_map ~f:Variants.top_lvl ty

    | "compare" ->
      List.concat_map ~f:(Compare.bindings ~kind) ty

    | "enumerate" ->
      List.map ~f:Enumerate.top_lvl ty

    | ext when cow_supported_extension ext ->
      let module Cow = Make_cow(struct let name = ext end) in
      List.concat_map ~f:Cow.bindings ty

    | _unsupported_ext -> []

  let generate_definitions ~ty ?ghost_loc ext =
    let bindings = List.concat_map ~f:(generate_bindings ~kind:`Def ~ty) ext in
    List.map (str_of_top_lvl ?ghost_loc) bindings

  let generate_sigs ~ty ?ghost_loc ext =
    let bindings = List.concat_map ~f:(generate_bindings ~kind:`Sig ~ty) ext in
    List.map (sig_of_top_lvl ?ghost_loc) bindings
end

module Nonrec = struct
  let type_nonrec_prefix = "\x00nonrec" (*"__nonrec_"*)
  let type_nonrec_prefix_l = String.length type_nonrec_prefix
  let add id =
    { id with Location.txt = type_nonrec_prefix ^ id.Location.txt }

  let is t =
    let l = String.length t in
    (l > type_nonrec_prefix_l) &&
    try
      for i = 0 to type_nonrec_prefix_l - 1 do
        if t.[i] <> type_nonrec_prefix.[i] then raise Not_found;
      done;
      true
    with Not_found -> false

  let drop t =
    let l = String.length t in
    if is t
    then String.sub t type_nonrec_prefix_l (l - type_nonrec_prefix_l)
    else t

  let ident_drop id =
    if is id.Ident.name
    then { id with Ident.name = drop id.Ident.name }
    else id
end
