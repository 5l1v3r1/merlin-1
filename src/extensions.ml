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

open Chunk_parser
type extension = {
  name : string;
  private_def : string list;
  public_def : string list;
  packages : string list;
  keywords : (string * Chunk_parser.token) list;
}

let ext_lwt = {
  name = "lwt";
  private_def = [
    "module Lwt : sig
      val un_lwt : 'a Lwt.t -> 'a
      val in_lwt : 'a Lwt.t -> 'a Lwt.t
      val to_lwt : 'a -> 'a Lwt.t
      val finally' : 'a Lwt.t -> unit Lwt.t -> 'a Lwt.t
      val un_stream : 'a Lwt_stream.t -> 'a
      val unit_lwt : unit Lwt.t -> unit Lwt.t
    end"
  ];
  public_def = [
    "val (>>) : unit Lwt.t -> 'a Lwt.t -> 'a Lwt.t
     val raise_lwt : exn -> 'a Lwt.t
     val assert_lwt : bool -> unit Lwt.t"
  ];
  keywords = [
    "lwt", LET_LWT;
    "try_lwt", TRY_LWT;
    "match_lwt", MATCH_LWT;
    "finally", FINALLY_LWT;
    "for_lwt", FOR_LWT;
    "while_lwt", WHILE_LWT;
  ];
  packages = ["lwt.syntax"];
}

let ext_any = {
  name = "any";
  private_def = [
    "module Any : sig
      val val' : 'a
    end"
  ];
  public_def = [];
  keywords = [];
  packages = [];
}

let ext_js = {
  name = "js";
  private_def = [
    "module Js : sig
      val un_js : 'a Js.t -> 'a
      val un_meth : 'a Js.meth -> 'a
      val un_constr : 'a Js.constr -> 'a
      val un_prop : 'a Js.gen_prop -> 'a
    end"
  ];
  public_def = [];
  keywords = ["jsnew", JSNEW];
  packages = ["js_of_ocaml.syntax"];
}

let ext_ounit = {
  name = "ounit";
  private_def = [
    "module OUnit : sig
      val force_bool : bool -> unit
      val force_unit : unit -> unit
      val force_unit_arrow_unit : (unit -> unit) -> unit
      val force_indexed : (int -> unit -> unit) -> int list -> unit
    end"
  ];
  public_def = [];
  keywords = [
    "TEST", OUNIT_TEST;
    "TEST_UNIT", OUNIT_TEST_UNIT;
    "TEST_MODULE", OUNIT_TEST_MODULE;
    "BENCH", OUNIT_BENCH;
    "BENCH_FUN", OUNIT_BENCH_FUN;
    "BENCH_INDEXED", OUNIT_BENCH_INDEXED;
    "BENCH_MODULE", OUNIT_BENCH_MODULE;
  ];
  packages = ["oUnit";"pa_ounit.syntax"];
}

let ext_nonrec = {
  name = "nonrec";
  private_def = [];
  public_def = [];
  keywords = [
    "nonrec", NONREC;
  ];
  packages = [];
}

let ext_here = {
  name = "here";
  private_def = [];
  public_def = ["val _here_ : Lexing.position"];
  keywords = [];
  packages = [];
}

let ext_pipebang = {
  name = "pipebang";
  private_def = [];
  public_def = ["val (|!) : 'a -> ('a -> 'b) -> 'b"];
  keywords = [];
  packages = [];
}

let ext_sexp_option = {
  name = "sexp_option";
  private_def = [];
  public_def = ["type 'a sexp_option = 'a option"];
  keywords = [];
  packages = [];
}

let always = [ext_any;ext_sexp_option]
let registry = [ext_here;ext_lwt;ext_js;ext_ounit;ext_nonrec;ext_pipebang]

