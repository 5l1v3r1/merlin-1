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

open Std
open Global_state

let sources_path = ref (Misc.Path_list.of_list [])
let cwd = ref ""

module Utils = struct
  let debug_log ?prefix x = Printf.ksprintf (Logger.log `locate ?prefix) x

  let is_ghost { Location. loc_ghost } = loc_ghost = true

  let path_to_list p =
    let rec aux acc = function
      | Path.Pident id -> id.Ident.name :: acc
      | Path.Pdot (p, str, _) -> aux (str :: acc) p
      | _ -> assert false
    in
    aux [] p

  let file_path_to_mod_name f =
    let pref = Misc.chop_extensions f in
    String.capitalize (Filename.basename pref)

  let find_file ?(ext=".cmt") file =
    let fname = Misc.chop_extension_if_any (Filename.basename file) ^ ext in
    (* FIXME: that sucks, if [cwd] = ".../_build/..." the ".ml" will exist, but
       will most likely not be the one you want to edit.
       However, just using [find_in_path_uncap] won't work either when you have
       several ml files with the same name (which can only happen in presence of packed
       modules).
       Example: scheduler.ml and raw_scheduler.ml are present in both async_core
       and async_unix. (ofc. "std.ml" is a more common example.)

       Note that [cwd] is set only when we have encountered a packed module, so in other
       cases [abs_cmt_file] will be something like "/file.ext" which (hopefully) won't
       exist. *)
    try Misc.find_in_path_uncap
          (Misc.Path_list.of_string_list_ref (ref [ !cwd ])) fname
    with Not_found ->
    try Misc.find_in_path_uncap !sources_path fname     with Not_found ->
    try Misc.find_in_path_uncap Project.cmt_path fname  with Not_found ->
    raise Not_found

  let keep_suffix =
    let open Longident in
    let rec aux = function
      | Lident str ->
        if String.lowercase str <> str then
          Some (Lident str, false)
        else
          None
      | Ldot (t, str) ->
        if String.lowercase str <> str then
          match aux t with
          | None -> Some (Lident str, true)
          | Some (t, is_label) -> Some (Ldot (t, str), is_label)
        else
          None
      | t ->
        Some (t, false) (* don't know what to do here, probably best if I do nothing. *)
    in
    function
    | Lident s -> Lident s, false
    | Ldot (t, s) ->
      begin match aux t with
      | None -> Lident s, true
      | Some (t, is_label) -> Ldot (t, s), is_label
      end
    | otherwise -> otherwise, false
end

include Utils

(** Reverse the list of structure items − we want to start from the bottom of
    the file − and remove top level indirections. *)
let get_browsable browsable =
  let items =
    List.rev_map (fun bt ->
      let open Browse in
      match bt.context with
      | TopStructure -> Lazy.force bt.nodes
      | _ -> [bt]
    ) browsable
  in
  List.concat items

let rec check_item modules =
  let get_loc ~name item rest =
    match item.Browse.context with
    | Browse.Pattern (Some id, _)
    | Browse.TypeDecl (id, _) when id.Ident.name = name ->
      Some item.Browse.loc
    | Browse.Module (Browse.Named id, _) when id = name ->
      Some item.Browse.loc
    | Browse.NamedOther id when id.Ident.name = name ->
      Some item.Browse.loc
    | Browse.Module (Browse.Include ids, _)
      when List.exists ids ~f:(fun i -> i.Ident.name = name) ->
      resolve_mod_alias ~fallback:item.Browse.loc (Lazy.force item.Browse.nodes)
        [ name ] rest
    | _ -> check_item modules rest
  in
  let get_on_track ~name item =
    match item.Browse.context with
    | Browse.Module (Browse.Named id, _) when id = name ->
      debug_log "(get_on_track) %s is an alias" name ;
      `Direct
    | Browse.Module (Browse.Include ids, _)
      when List.exists (fun i -> i.Ident.name = name) ids ->
      debug_log "(get_on_track) %s is included..." name ;
      `Included
    | _ -> `Not_found
  in
  function
  | [] ->
    debug_log "%s not in current file..." (String.concat ~sep:"." modules) ;
    from_path' modules
  | item :: rest ->
    match modules with
    | [] -> assert false
    | [ str_ident ] -> get_loc ~name:str_ident item rest
    | mod_name :: path ->
      begin match
        match get_on_track ~name:mod_name item with
        | `Not_found -> None
        | `Direct -> Some path
        | `Included -> Some modules
      with
      | None -> check_item modules rest
      | Some path ->
        resolve_mod_alias ~fallback:item.Browse.loc
          (Lazy.force item.Browse.nodes) path rest
      end

and browse_cmts ~root modules =
  let open Cmt_format in
  let cmt_infos = read_cmt root in
  match cmt_infos.cmt_annots with
  | Implementation impl ->
    begin match modules with
    | [] -> (* we were looking for a module, we found the right file, we're happy *)
      let pos_fname = root in
      let pos = { Lexing. pos_fname ; pos_lnum = 1 ; pos_cnum = 0 ; pos_bol = 0 } in
      Some { Location. loc_start = pos ; loc_end = pos ; loc_ghost = false }
    | _ ->
      let browses   = Browse.structure impl in
      let browsable = get_browsable browses in
      check_item modules browsable
    end
  | Packed (_, files) ->
    begin match modules with
    | [] -> None
    | mod_name :: modules ->
      let file = List.find files ~f:(fun f -> file_path_to_mod_name f = mod_name) in
      cwd := Filename.dirname root ;
      debug_log "Saw packed module => setting cwd to '%s'" !cwd ;
      let cmt_file = find_file file in
      browse_cmts ~root:cmt_file modules
    end
  | _ -> None (* TODO? *)

and from_path' ?fallback =
  let recover = function
    | None -> fallback
    | Some v -> Some v
  in
  function
  | [] -> invalid_arg "empty path"
  | [ fname ] ->
    let pos = { Lexing. pos_fname = fname ; pos_lnum = 1 ; pos_cnum = 0 ; pos_bol = 0 } in
    Some { Location. loc_start = pos ; loc_end = pos ; loc_ghost = false }
  | fname :: modules ->
    try
      let cmt_file = find_file fname in
      recover (browse_cmts ~root:cmt_file modules)
    with Not_found ->
      recover None

and resolve_mod_alias ~fallback mod_item path rest =
  let open Browse in
  let do_fallback = function
    | None   -> Some fallback
    | Some x -> Some x
  in
  match mod_item with
  | [ { context = TopStructure ; nodes } ] ->
    (* Indirection, recurse. *)
    resolve_mod_alias ~fallback (Lazy.force nodes) path rest
  | [ { context = Module (Alias path', _) } ] ->
    let full_path = (path_to_list path') @ path in
    do_fallback (check_item full_path rest)
  | [ { context = Module (Structure, _) ; nodes } ] ->
    let browsable = get_browsable (Lazy.force nodes) @ rest in
    do_fallback (check_item path browsable)
  | [ { context = Module (Mod_apply, _) ; loc } ] ->
    (* We don't want to follow functors instantiation *)
    debug_log "stopping on functor instantiation" ;
    Some loc
  | otherwise ->
    let browsable = get_browsable otherwise @ rest in
    do_fallback (check_item path browsable)

let path_and_loc_from_cstr desc env =
  let open Types in
  match desc.cstr_tag with
  | Cstr_exception (path, loc) -> path, loc
  | _ ->
    match desc.cstr_res.desc with
    | Tconstr (path, _, _) ->
      let typ_decl = Env.find_type path env in
      path, typ_decl.Types.type_loc
    | _ -> assert false

let path_and_loc_from_label desc env =
  let open Types in
  match desc.lbl_res.desc with
  | Tconstr (path, _, _) ->
    let typ_decl = Env.find_type path env in
    path, typ_decl.Types.type_loc
  | _ -> assert false

let from_string ~sources ~env ~local_defs ~local_modules path =
  debug_log "looking for the source of '%s'" path ;
  sources_path := sources;
  let ident, is_label = keep_suffix (Longident.parse path) in
  try
    let path, loc =
      if is_label then
        let label_desc = Merlin_types.lookup_label ident env in
        path_and_loc_from_label label_desc env
      else (
        try
          let path, val_desc = Env.lookup_value ident env in
          path, val_desc.Types.val_loc
        with Not_found ->
        try
          let path, typ_decl = Env.lookup_type ident env in
          path, typ_decl.Types.type_loc
        with Not_found ->
        try
          let cstr_desc = Merlin_types.lookup_constructor ident env in
          path_and_loc_from_cstr cstr_desc env
        with Not_found ->
        try
          let path, _ = Env.lookup_module ident env in
          let starting_point = Path.head path in
          let is_local =
            let rec aux =
              let open Env in
              function
              | Env_empty -> false
              | Env_module (_, id, _) when Ident.same starting_point id -> true
              | Env_value (summary, _, _)
              | Env_type (summary, _, _)
              | Env_exception (summary, _, _)
              | Env_module (summary, _, _)
              | Env_modtype (summary, _, _)
              | Env_class (summary, _, _)
              | Env_cltype (summary, _, _)
              | Env_open (summary, _) -> aux summary
            in
            aux (Env.summary env)
          in
          let loc =
            if not is_local then
              Location.symbol_gloc ()
            else
              let () = debug_log "which is a local module..." in
              try
                (* FIXME: will only give the oldest ancestor of the searched
                   module, not the module itself... *)
                List.assoc (Ident.name starting_point) local_modules
              with Not_found ->
                Location.symbol_gloc ()
          in
          path, loc
        with Not_found ->
          debug_log "   ... not in the environment" ;
          raise Not_found
      )
    in
    if not (is_ghost loc) then
      Some (None, loc)
    else
      let opt =
        let modules = path_to_list path in
        let local_defs =
          (* looks like local_defs is already in reversed order. So we need to
             reverse it here (since [get_browsable] is going to reverse it one
             last time). *)
          List.rev_map local_defs ~f:(fun s -> Browse.structure s.Asttypes.txt)
        in
        check_item modules (get_browsable (List.concat local_defs))
      in
      Option.map opt ~f:(fun loc ->
        let fname = loc.Location.loc_start.Lexing.pos_fname in
        let full_path = find_file ~ext:".ml" fname in
        Some full_path, loc
      )
  with Not_found ->
    None
