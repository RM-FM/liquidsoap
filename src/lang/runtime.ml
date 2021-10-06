(*****************************************************************************

  Liquidsoap, a programmable audio stream generator.
  Copyright 2003-2021 Savonet team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details, fully stated in the COPYING
  file at the root of the liquidsoap distribution.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301  USA

 *****************************************************************************)

(** {1 Running} *)

let () = Lang.apply_fun := Evaluation.apply

let type_and_run ~throw ~lib ast =
  Clock.collect_after (fun () ->
      if Lazy.force Term.debug then Printf.eprintf "Type checking...\n%!";
      (* Type checking *)
      Typechecking.check ~throw ~ignored:true ast;

      if Lazy.force Term.debug then
        Printf.eprintf "Checking for unused variables...\n%!";
      (* Check for unused variables, relies on types *)
      Term.check_unused ~throw ~lib ast;
      if Lazy.force Term.debug then Printf.eprintf "Evaluating...\n%!";
      ignore (Evaluation.eval_toplevel ast))

(** {1 Error reporting} *)

let error = Console.colorize [`red; `bold] "Error"
let warning = Console.colorize [`magenta; `bold] "Warning"
let position pos = Console.colorize [`bold] (String.capitalize_ascii pos)

let error_header idx pos =
  Format.printf "@[%s:\n%s %i: " (position pos) error idx

let warning_header idx pos =
  Format.printf "@[%s:\n%s %i: " (position pos) warning idx

(** Exception raised by report_error after an error has been displayed.
  * Unknown errors are re-raised, so that their content is not totally lost. *)
exception Error

let strict = ref false

let throw print_error = function
  (* Warnings *)
  | Term.Ignored tm when Term.is_fun (Type.deref tm.Term.t) ->
      flush_all ();
      warning_header 1 (Type.print_pos_opt tm.Term.t.Type.pos);
      Format.printf
        "This function application is partial,@ being of type %s.@ Maybe some \
         arguments are missing.@]@."
        (Type.print tm.Term.t);
      if !strict then raise Error
  | Term.Ignored tm when Term.is_source (Type.deref tm.Term.t) ->
      flush_all ();
      warning_header 2 (Type.print_pos_opt tm.Term.t.Type.pos);
      Format.printf
        "This source is unused, maybe it needs to@ be connected to an \
         output.@]@.";
      if !strict then raise Error
  | Term.Ignored tm ->
      flush_all ();
      warning_header 3 (Type.print_pos_opt tm.Term.t.Type.pos);
      Format.printf "This expression should have type unit.@]@.";
      if !strict then raise Error
  | Term.Unused_variable (s, pos) ->
      flush_all ();
      warning_header 4 (Type.print_single_pos pos);
      Format.printf "Unused variable %s@]@." s;
      if !strict then raise Error
  (* Errors *)
  | Failure s when s = "lexing: empty token" ->
      print_error 1 "Empty token";
      raise Error
  | Parser.Error | Parsing.Parse_error ->
      print_error 2 "Parse error";
      raise Error
  | Term.Parse_error (pos, s) ->
      let pos = Type.print_pos pos in
      error_header 3 pos;
      Format.printf "%s@]@." s;
      raise Error
  | Term.Unbound (pos, s) ->
      let pos = Type.print_pos_opt pos in
      error_header 4 pos;
      Format.printf "Undefined variable %s@]@." s;
      raise Error
  | Type.Type_error explain ->
      flush_all ();
      Type.print_type_error (error_header 5) explain;
      raise Error
  | Term.No_label (f, lbl, first, x) ->
      let pos_f = Type.print_pos_opt f.Term.t.Type.pos in
      let pos_x = Type.print_pos_opt x.Term.t.Type.pos in
      flush_all ();
      error_header 6 pos_x;
      Format.printf
        "Cannot apply that parameter because the function %s@ has %s@ %s!@]@."
        pos_f
        (if first then "no" else "no more")
        (if lbl = "" then "unlabeled argument"
        else Format.sprintf "argument labeled %S" lbl);
      raise Error
  | Error.Invalid_value (v, msg) ->
      error_header 7 (Type.print_pos_opt v.Value.pos);
      Format.printf "Invalid value:@ %s@]@." msg;
      raise Error
  | Lang_encoder.Encoder_error (pos, s) ->
      error_header 8 (Type.print_pos_opt pos);
      Format.printf "%s@]@." (String.capitalize_ascii s);
      raise Error
  | Failure s ->
      print_error 9 (Printf.sprintf "Failure: %s" s);
      raise Error
  | Error.Clock_conflict (pos, a, b) ->
      (* TODO better printing of clock errors: we don't have position
       *   information, use the source's ID *)
      error_header 10 (Type.print_pos_opt pos);
      Format.printf "A source cannot belong to two clocks (%s,@ %s).@]@." a b;
      raise Error
  | Error.Clock_loop (pos, a, b) ->
      error_header 11 (Type.print_pos_opt pos);
      Format.printf "Cannot unify two nested clocks (%s,@ %s).@]@." a b;
      raise Error
  | Error.Kind_conflict (pos, a, b) ->
      error_header 10 (Type.print_pos_opt pos);
      Format.printf "Source kinds don't match@ (%s vs@ %s).@]@." a b;
      raise Error
  | Term.Unsupported_format (pos, fmt) ->
      let pos = Type.print_pos_opt pos in
      error_header 12 pos;
      Format.printf
        "Unsupported format: %s.@ You must be missing an optional \
         dependency.@]@."
        fmt;
      raise Error
  | Term.Internal_error (pos, e) ->
      let pos = Type.print_pos_list pos in
      (* Bad luck, error 13 should never have happened. *)
      error_header 13 pos;
      Format.printf "Internal error: %s@]@." e;
      raise Error
  | Term.Runtime_error { Term.kind; msg; pos } ->
      let pos = Type.print_pos_list pos in
      error_header 14 pos;
      Format.printf "Uncaught runtime error:@ type: %s,@ message: %s@]@." kind
        (Printf.sprintf "%s" (Utils.quote_string msg));
      raise Error
  | Sedlexing.MalFormed -> print_error 13 "Malformed file."
  | End_of_file -> raise End_of_file
  | e ->
      let bt = Printexc.get_backtrace () in
      error_header (-1) "unknown position";
      Format.printf "Exception raised: %s@.%s@]@." (Printexc.to_string e) bt;
      raise Error

let report lexbuf f =
  let print_error idx error =
    flush_all ();
    let pos =
      let start = snd (Sedlexing.lexing_positions lexbuf) in
      let buf = Sedlexing.Utf8.lexeme lexbuf in
      Printf.sprintf "%sine %d, char %d%s"
        (if start.Lexing.pos_fname = "" then "L"
        else
          Printf.sprintf "File %s, l"
            (Utils.quote_string start.Lexing.pos_fname))
        start.Lexing.pos_lnum
        (start.Lexing.pos_cnum - start.Lexing.pos_bol)
        (if buf = "" then "" else Printf.sprintf " before %S" buf)
    in
    error_header idx pos;
    Format.printf "%s\n@]@." error
  in
  let throw = throw print_error in
  if Term.conf_debug_errors#get then f ~throw ()
  else (try f ~throw () with exn -> throw exn)

(** {1 Parsing} *)

let mk_expr ?fname ~pwd processor lexbuf =
  let processor = MenhirLib.Convert.Simplified.traditional2revised processor in
  let tokenizer = Preprocessor.mk_tokenizer ?fname ~pwd lexbuf in
  let tokenizer () =
    let token, (startp, endp) = tokenizer () in
    (token, startp, endp)
  in
  processor tokenizer

let from_lexbuf ?fname ?(dir = Unix.getcwd ()) ?(parse_only = false) ~ns ~lib
    lexbuf =
  begin
    match ns with
    | Some ns -> Sedlexing.set_filename lexbuf ns
    | None -> ()
  end;
  try
    report lexbuf (fun ~throw () ->
        let expr = mk_expr ?fname ~pwd:dir Parser.program lexbuf in
        if not parse_only then type_and_run ~throw ~lib expr)
  with Error -> exit 1

let from_in_channel ?fname ?dir ?parse_only ~ns ~lib in_chan =
  let lexbuf = Sedlexing.Utf8.from_channel in_chan in
  from_lexbuf ?fname ?dir ?parse_only ~ns ~lib lexbuf

let from_file ?parse_only ~ns ~lib filename =
  let ic = open_in filename in
  let fname = Utils.home_unrelate filename in
  from_in_channel ~fname
    ~dir:(Filename.dirname filename)
    ?parse_only ~ns ~lib ic;
  close_in ic

let load_libs ?(error_on_no_stdlib = true) ?parse_only ?(deprecated = true) () =
  let dir = Configure.liq_libs_dir in
  let file = Filename.concat dir "stdlib.liq" in
  if not (Sys.file_exists file) then (
    if error_on_no_stdlib then
      failwith "Could not find default stdlib.liq library!")
  else from_file ?parse_only ~ns:(Some file) ~lib:true file;
  let file = Filename.concat dir "deprecations.liq" in
  if deprecated && Sys.file_exists file then
    from_file ?parse_only ~ns:(Some file) ~lib:true file

let from_file = from_file ~ns:None

let from_string ?parse_only ~lib expr =
  let lexbuf = Sedlexing.Utf8.from_string expr in
  from_lexbuf ?parse_only ~ns:None ~lib lexbuf

let eval ~ignored ~ty s =
  let lexbuf = Sedlexing.Utf8.from_string s in
  let expr = mk_expr ~pwd:(Unix.getcwd ()) Parser.program lexbuf in
  let expr = Term.(make (Cast (expr, ty))) in
  Clock.collect_after (fun () ->
      report lexbuf (fun ~throw () -> Typechecking.check ~throw ~ignored expr);
      Evaluation.eval expr)

let from_in_channel ?parse_only ~lib x =
  from_in_channel ?parse_only ~ns:None ~lib x

let interactive () =
  Format.printf
    "\n\
     Welcome to the liquidsoap interactive loop.\n\n\
     You may enter any sequence of expressions, terminated by \";;\".\n\
     Each input will be fully processed: parsing, type-checking,\n\
     evaluation (forces default types), output startup (forces default clock).\n\
     @.";
  if Dtools.Log.conf_file#get then
    Format.printf "Logs can be found in %s.\n@."
      (Utils.quote_string Dtools.Log.conf_file_path#get);
  let lexbuf =
    (* See ocaml-community/sedlex#45 *)
    let chunk_size = 512 in
    let buf = Bytes.create chunk_size in
    let cached = ref (-1) in
    let position = ref (-1) in
    let rec gen () =
      match (!position, !cached) with
        | _, 0 -> None
        | -1, _ ->
            position := 0;
            cached := input stdin buf 0 chunk_size;
            gen ()
        | len, c when len = c ->
            position := -1;

            (* This means that the last read was a full chunk. Safe to try a new
               one right away. *)
            if len = chunk_size then gen () else None
        | len, _ ->
            position := len + 1;
            Some (Bytes.get buf len)
    in
    Sedlexing.Utf8.from_gen gen
  in
  let rec loop () =
    Format.printf "# %!";
    if
      try
        report lexbuf (fun ~throw () ->
            let expr =
              mk_expr ~pwd:(Unix.getcwd ()) Parser.interactive lexbuf
            in
            Typechecking.check ~throw ~ignored:false expr;
            Term.check_unused ~throw ~lib:true expr;
            Clock.collect_after (fun () ->
                ignore (Evaluation.eval_toplevel ~interactive:true expr)));
        true
      with
        | End_of_file ->
            Format.printf "Bye bye!@.";
            false
        | Error -> true
        | e ->
            let e = Console.colorize [`white; `bold] (Printexc.to_string e) in
            Format.printf "Exception: %s!@." e;
            true
    then loop ()
  in
  loop ();
  Tutils.shutdown 0