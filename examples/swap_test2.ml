(*
 * Copyright (c) 2015, Théo Laurent <theo.laurent@ens.fr>
 *
 * Permission to use, copy, modify, and/or distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Printf
module Scheduler = Sched_work_stealing.Make(struct let num_domains = 1 end)
module Reagents = Reagents.Make (Scheduler)
open Scheduler
open Reagents
open Reagents.Channel
open Reagents.Ref

let id_str () = sprintf "%d:%d" (Domain.self ()) (get_tid ())

let main () =
  Printf.printf "This example blocks\n%!";
  let (a,b) = mk_chan () in
  let r = mk_ref 0 in
  fork (fun () -> 
    run (swap a >>> 
         upd r (fun _ () -> Some (1, ()))) ());
  run (swap b >>> 
       upd r (fun _ () -> Some (2, ()))) ()

let () = Scheduler.run main
