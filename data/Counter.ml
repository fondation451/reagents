(*
 * Copyright (c) 2015, KC Sivaramakrishnan <sk826@cl.cam.ac.uk>
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

module type S = sig
  type t
  type ('a,'b) reagent
  val create  : int -> t
  val get     : t -> (unit, int) reagent
  val inc     : t -> (unit, int) reagent
  val dec     : t -> (unit, int) reagent
  val try_dec : t -> (unit, int option) reagent
end

module Make (Reagents : Reagents.S) : S
  with type ('a,'b) reagent = ('a,'b) Reagents.t = struct

  module Ref = Reagents.Ref
  type ('a,'b) reagent = ('a,'b) Reagents.t

  type t = int Ref.ref

  let create init = Ref.mk_ref init
  let get r = Ref.read r
  let inc r = Ref.upd r (fun i () -> Some (i+1,i))
  let dec r = Ref.upd r (fun i () -> if i > 0 then Some (i-1,i) else None)
  let try_dec r = Ref.upd r (fun i () ->
    if i > 0 then Some (i-1,Some i) else Some (0, None))
end
