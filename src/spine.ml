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
type position = int

let rec try_ntimes n f s =
  if n > 0 then
    match f s with
      | None -> None
      | Some s' -> try_ntimes (pred n) f s'
  else Some s

module type CONTEXT = sig
  type state

  type sig_item
  type str_item
  type sig_in_sig_modtype
  type sig_in_sig_module
  type sig_in_str_modtype
  type str_in_module
end

module type STEP = sig
  module Context : CONTEXT

  type ('a,'b) step
  val value    : ('a, 'b) step -> 'a
  val state    : ('a, 'b) step -> Context.state
  val parent   : ('a, 'b) step -> 'b
  val position : ('a, 'b) step -> position
end

module type S = sig
  include STEP

  type t_sig =
    | Sig_root of (unit, unit) step
    | Sig_item of (Context.sig_item, t_sig) step
    | Sig_in_sig_modtype of (Context.sig_in_sig_modtype, t_sig) step
    | Sig_in_sig_module  of (Context.sig_in_sig_module,  t_sig) step
    | Sig_in_str_modtype of (Context.sig_in_str_modtype, t_str) step

  and t_str =
    | Str_root of (unit, unit) step
    | Str_item of (Context.str_item, t_str) step
    | Str_in_module of (Context.str_in_module, t_str) step

  type t =
    | Str of t_str
    | Sig of t_sig

  val sig_position : t_sig -> int
  val str_position : t_str -> int
  val position : t -> int

  val str_previous : t_str -> t option
  val sig_previous : t_sig -> t option
  val previous : t -> t option

  val str_state : t_str -> Context.state
  val sig_state : t_sig -> Context.state
  val get_state : t -> Context.state

  val dump :  ?sig_item:(string -> Context.state -> Context.sig_item -> string)
           -> ?str_item:(string -> Context.state -> Context.str_item -> string)
           -> ?state:(string -> Context.state -> string)
           -> t -> string list
end

module Make_S (Step : STEP) :
  S with module Context = Step.Context and type ('a,'b) step = ('a,'b) Step.step =
struct
  include Step
  open Context

  type t_sig =
    | Sig_root of (unit, unit) step
    | Sig_item of (sig_item, t_sig) step
    | Sig_in_sig_modtype of (sig_in_sig_modtype, t_sig) step
    | Sig_in_sig_module  of (sig_in_sig_module,  t_sig) step
    | Sig_in_str_modtype of (sig_in_str_modtype, t_str) step

  and t_str =
    | Str_root of (unit, unit) step
    | Str_item of (str_item, t_str) step
    | Str_in_module of (str_in_module, t_str) step

  type t =
    | Str of t_str
    | Sig of t_sig

  let str_position = function
    | Str_root _ -> 0
    | Str_item step -> position step
    | Str_in_module step -> position step

  let sig_position = function
    | Sig_root _ -> 0
    | Sig_item step -> position step
    | Sig_in_str_modtype step -> position step
    | Sig_in_sig_module step  -> position step
    | Sig_in_sig_modtype step -> position step

  let position = function
    | Sig sg  -> sig_position sg
    | Str str -> str_position str

  let str_previous = function
    | Str_root _ -> None
    | Str_item step -> Some (Str (parent step))
    | Str_in_module step -> Some (Str (parent step))

  let sig_previous = function
    | Sig_root _ -> None
    | Sig_item step -> Some (Sig (parent step))
    | Sig_in_sig_module step  -> Some (Sig (parent step))
    | Sig_in_sig_modtype step -> Some (Sig (parent step))
    | Sig_in_str_modtype step -> Some (Str (parent step))

  let previous = function
    | Sig sg  -> sig_previous sg
    | Str str -> str_previous str

  let str_state = function
    | Str_root step -> state step
    | Str_item step -> state step
    | Str_in_module step -> state step

  let sig_state = function
    | Sig_root step -> state step
    | Sig_item step -> state step
    | Sig_in_sig_module step  -> state step
    | Sig_in_sig_modtype step -> state step
    | Sig_in_str_modtype step -> state step

  let get_state = function
    | Sig sg  -> sig_state sg
    | Str str -> str_state str

  let dump ?(sig_item=fun s _ _ -> s)
           ?(str_item=fun s _ _ -> s)
           ?state:(pr_state=fun s _ -> s)
           t
           =
    let rec dump_sig acc = function
      | Sig_root step -> pr_state "sig_root" (state step) :: acc
      | Sig_item step ->
        dump_sig (sig_item "sig_item" (state step) (value step) :: acc) (parent step)
      | Sig_in_sig_module step ->
        dump_sig (pr_state "sig_in_sig_module" (state step) :: acc) (parent step)
      | Sig_in_sig_modtype step ->
        dump_sig (pr_state "sig_in_sig_modtype" (state step) :: acc) (parent step)
      | Sig_in_str_modtype step ->
        dump_str (pr_state "sig_in_str_modtype" (state step) :: acc) (parent step)
    and dump_str acc = function
      | Str_root step -> pr_state "str_root" (state step) :: acc
      | Str_item step ->
        dump_str (str_item "str_item" (state step) (value step) :: acc) (parent step)
      | Str_in_module step ->
        dump_str (pr_state "str_in_module" (state step) :: acc) (parent step)
    in
    match t with
    | Sig s -> dump_sig ["SIG"] s
    | Str s -> dump_str ["STRUCT"] s

end

module Initial (Context : CONTEXT) :
sig
  include S
  val sig_step : t_sig -> Context.state -> 'a -> ('a,t_sig) step
  val str_step : t_str -> Context.state -> 'a -> ('a,t_str) step

  val initial : Context.state -> (unit, unit) step
end with module Context = Context =
struct
  module Step = struct
    module Context = Context
    open Context
    type ('a,'b) step = {
      value: 'a;
      state: state;
      position: position;
      parent: 'b;
    }
    let value t = t.value
    let state t = t.state
    let position t = t.position
    let parent t = t.parent
  end
  include Make_S (Step)

  let str_step str state value =
    let position = succ (str_position str) in
    {Step. value; state; position; parent = str}

  let sig_step sg state value =
    let position = succ (sig_position sg) in
    {Step. value; state; position; parent = sg}

  let initial state =
    {Step. value = (); state; position = 0; parent = ()}
end

module Transform (Context : CONTEXT) (Dom : S)
  (Fold : sig
    (* Initial state *)
    val sig_root : (unit, unit) Dom.step -> Context.state
    val str_root : (unit, unit) Dom.step -> Context.state

    (* Fold items *)
    val sig_item
      :  (Dom.Context.sig_item, Dom.t_sig) Dom.step
      -> ?back_from:Context.state
      -> Context.state
      -> Context.state * Context.sig_item
    val str_item
      :  (Dom.Context.str_item, Dom.t_str) Dom.step
      -> ?back_from:Context.state
      -> Context.state
      -> Context.state * Context.str_item

    (* Fold signature shape *)
    val sig_in_sig_modtype
      :  (Dom.Context.sig_in_sig_modtype, Dom.t_sig) Dom.step
      -> Context.state -> Context.state * Context.sig_in_sig_modtype
    val sig_in_sig_module
      :  (Dom.Context.sig_in_sig_module, Dom.t_sig) Dom.step
      -> Context.state -> Context.state * Context.sig_in_sig_module
    val sig_in_str_modtype
      :  (Dom.Context.sig_in_str_modtype, Dom.t_str) Dom.step
      -> Context.state -> Context.state * Context.sig_in_str_modtype

    (* Fold structure shape *)
    val str_in_module
      :  (Dom.Context.str_in_module, Dom.t_str) Dom.step
      -> Context.state -> Context.state * Context.str_in_module

    (* Validate state before incremental update
     * (return false iff current step can't be used as a starting point for
     *  incremental update)  *)
    val is_valid : Dom.t -> Context.state -> bool
   end) :
sig
  module Dom : S
  include S
  val rewind : Dom.t -> t -> Dom.t * t
  val update : Dom.t -> t option -> t
end with module Dom = Dom and module Context = Context =
struct
  module Dom = Dom

  module Step = struct
    module Context = Context
    open Context
    type ('a,'b) step = {
      value: 'a;
      state: state;
      position: position;
      parent: 'b;
      sync: [`Sig of Dom.t_sig Sync.t
            |`Str of Dom.t_str Sync.t]
    }
    let value t = t.value
    let state t = t.state
    let position t = t.position
    let parent t = t.parent
  end

  include Make_S (Step)

  let make_sync_str str = `Str (Sync.make str)
  let make_sync_sig sg  = `Sig (Sync.make sg)

  let sig_step sync parent state value =
    let position = succ (sig_position parent) in
    {Step. value; state; position; parent; sync}

  let str_step sync parent state value =
    let position = succ (str_position parent) in
    {Step. value; state; position; parent; sync}

  let initial sync state =
    {Step. value = (); state; position = 0; parent = (); sync}

  let str_sync = function
    | Str_root {Step.sync} | Str_item {Step.sync} | Str_in_module {Step.sync} ->
      sync

  let sig_sync = function
    | Sig_root {Step.sync} | Sig_item {Step.sync}
    | Sig_in_str_modtype {Step.sync} | Sig_in_sig_module {Step.sync}
    | Sig_in_sig_modtype {Step.sync} ->
      sync

  let sync = function
    | Sig sg  -> sig_sync sg
    | Str str -> str_sync str

  let same_sig sg = function
    | `Sig sync -> Sync.same sg sync
    | _ -> false

  let same_str str = function
    | `Str sync -> Sync.same str sync
    | _ -> false

  let same = fun _ _ -> true (*function
    | Dom.Sig sg  -> same_sig sg
    | Dom.Str str -> same_str str*)

  let rewind dom cod =
    let pd = Dom.position dom and pc = position cod in
    match
      try_ntimes (pd - pc) Dom.previous dom,
      try_ntimes (pc - pd) previous cod
    with
    | None, _ | _, None -> assert false
    | Some dom, Some cod ->
    let rec aux dom cod =
      if same dom (sync cod)
      then dom, cod
      else match Dom.previous dom, previous cod with
        | None, Some _ | Some _, None -> assert false
        | Some dom, Some cod -> aux dom cod
        | None, None ->
        match dom with
        | Dom.Sig (Dom.Sig_root step as sg) ->
          dom, Sig (Sig_root (initial (make_sync_sig sg) (Fold.sig_root step)))
        | Dom.Str (Dom.Str_root step as str) ->
          dom, Str (Str_root (initial (make_sync_str str) (Fold.str_root step)))
        | _ -> assert false
    in
    aux dom cod

  let get_sig = function
    | Sig sg -> sg
    | Str _  -> assert false

  let get_str = function
    | Str str -> str
    | Sig _  -> assert false

  let previous' pos dom = function
    | Some cod when pos dom = position cod -> previous cod
    | cod' -> cod'

  let update dom cod' =
    let pd = Dom.position dom in
    let cod = match cod' with
      | None -> None
      | Some cod ->
        match try_ntimes (position cod - pd) previous cod with
        | None -> assert false
        | Some cod as result ->
          assert (position cod <= pd);
          result
    in
    let back_from =
      match cod' with
      | None -> None
      | Some cod' ->
        match dom, cod with
        | Dom.Sig (Dom.Sig_item _),
          Some (Sig (Sig_in_sig_modtype _ | Sig_in_sig_module _))
        | Dom.Str (Dom.Str_item _),
          Some (Sig (Sig_in_str_modtype _) | Str (Str_in_module _))
          -> Some (position cod' - 1, get_state cod')
        | _ -> None
    in
    let back_from get_pos dom =
      match back_from with
      | Some (position, state) when position = get_pos dom ->
        Some state
      | _ -> None
    in
    let rec fold_str dom cod k =
      match cod with
      | Some cod when same_str dom (sync cod)
                   && Fold.is_valid (Dom.Str dom) (get_state cod) ->
          k (get_str cod)
      | _ ->
      let previous = previous' Dom.str_position dom cod in
      match dom with
      | Dom.Str_root step -> k (Str_root (initial (make_sync_str dom) (Fold.str_root step)))
      | Dom.Str_item step ->
        fold_str (Dom.parent step) previous
          (fun cod ->
             let state, item = Fold.str_item step ?back_from:(back_from Dom.str_position dom) (str_state cod) in
             k (Str_item (str_step (make_sync_str dom) cod state item)))

      | Dom.Str_in_module step ->
        fold_str (Dom.parent step) previous
          (fun cod ->
             let state, value = Fold.str_in_module step (str_state cod) in
             k (Str_in_module (str_step (make_sync_str dom) cod state value)))
    and fold_sig dom cod k =
      match cod with
      | Some cod when same_sig dom (sync cod)
                   && Fold.is_valid (Dom.Sig dom) (get_state cod) ->
          k (get_sig cod)
      | _ ->
      let previous = previous' Dom.sig_position dom cod in
      match dom with
      | Dom.Sig_root step -> k (Sig_root (initial (make_sync_sig dom) (Fold.sig_root step)))

      | Dom.Sig_item step ->
        fold_sig (Dom.parent step) previous
          (fun cod ->
             let state, item = Fold.sig_item step ?back_from:(back_from Dom.sig_position dom) (sig_state cod) in
             k (Sig_item (sig_step (make_sync_sig dom) cod state item)))

      | Dom.Sig_in_sig_modtype step ->
        fold_sig (Dom.parent step) previous
          (fun cod ->
             let state, value = Fold.sig_in_sig_modtype step (sig_state cod) in
             k (Sig_in_sig_modtype (sig_step (make_sync_sig dom) cod state value)))

      | Dom.Sig_in_sig_module step ->
        fold_sig (Dom.parent step) previous
          (fun cod ->
             let state, value = Fold.sig_in_sig_module step (sig_state cod) in
             k (Sig_in_sig_module (sig_step (make_sync_sig dom) cod state value)))

      | Dom.Sig_in_str_modtype step ->
        fold_str (Dom.parent step) previous
          (fun cod ->
             let state, value = Fold.sig_in_str_modtype step (str_state cod) in
             k (Sig_in_str_modtype (str_step (make_sync_sig dom) cod state value)))
    in
    match dom with
    | Dom.Sig dom -> fold_sig dom cod (fun r -> Sig r)
    | Dom.Str dom -> fold_str dom cod (fun r -> Str r)
end
