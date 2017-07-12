(*
 * Copyright (c) 2015, Théo Laurent <theo.laurent@ens.fr>
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
  type ('a,'b) endpoint
  type ('a,'b) reagent

  val mk_chan : ?name:string -> unit -> ('a,'b) endpoint * ('b,'a) endpoint
  val swap    : ('a,'b) endpoint -> ('a,'b) reagent
end

module Make (Sched : Scheduler.S) : S with
  type ('a,'b) reagent = ('a,'b) Reagent.Make(Sched).t = struct

  module Reagent = Reagent.Make(Sched)
  module Reaction = Reaction.Make(Sched)
  module Offer = Offer.Make(Sched)
  module Bag = Lockfree.Bag_Custom(struct let nb_domains = 2;; end);;

  open Reagent

  type ('a,'b) reagent = ('a,'b) Reagent.t

  type ('a,'b) message =
    Message : 'c Offer.t * ('b,'a) t -> ('a,'b) message

  let mk_message (type a) (type b) (type c) (payload : a) (sender_rx : Reaction.t)
                 (sender_k : (b,c) t) (sender_offer : c Offer.t) =
    let try_react payload sender_offer sender_rx receiver_k c receiver_rx receiver_offer =
      let rx = Reaction.union sender_rx receiver_rx in
      let cas = Offer.complete sender_offer c in
      let new_rx =
        if can_cas_immediate receiver_k rx receiver_offer then
          match PostCommitCas.commit cas with
          | None -> None
          | Some f -> ( f (); Some rx )
        else Some (Reaction.with_CAS rx cas)
      in
      match new_rx with
      | None -> Retry
      | Some new_rx -> receiver_k.try_react payload new_rx receiver_offer
    in
    let rec complete_exchange : 'd. (a,'d) t -> (c,'d) t =
      fun receiver_k ->
        { always_commits = false;
          compose = (fun next -> complete_exchange (receiver_k.compose next));
          try_react = try_react payload sender_offer sender_rx receiver_k}
    in
    let complete_exchange =
          sender_k.compose (complete_exchange Reagent.commit)
    in
    Message (sender_offer, complete_exchange)

  type ('a,'b) endpoint =
    { name : string;
      outgoing: ('a,'b) message Bag.t;
      incoming: ('b,'a) message Bag.t }

  let mk_chan ?name () =
    let name =
      match name with
      | None -> ""
      | Some n -> n
    in
    let l1 = Bag.create () in
    let l2 = Bag.create () in
    {name = "+" ^ name; incoming = l1; outgoing = l2},
    {name = "-" ^ name; incoming = l2; outgoing = l1}

  let message_is_active (Message (o,_)) = Offer.is_active o

  let rec swap : 'a 'b 'r. ('a,'b) endpoint -> ('b,'r) reagent -> ('a,'r) reagent =
    let try_react ep k a rx offer =
      let {name; outgoing; incoming} = ep in
      (* Search for matching offers *)
      let rec try_from elem retry save =
        let rec repush_offer l out =
          match l with
          |h::t -> Bag.push incoming h; repush_offer t out
          |[] -> out
        in
        match elem with
        | None -> if retry then repush_offer save Retry else repush_offer save Block
        | Some (Message (sender_offer,exchange) as elem_saved) ->
            let same_offer o = function
            | None -> false
            | Some o' -> Offer.equal o o'
            in
            ( if (not (Offer.is_active sender_offer))
                || Reaction.has_offer rx sender_offer
                || same_offer sender_offer offer then
(*                   let _ = Printf.printf "me!!\n" in*)
                  try_from (Bag.pop incoming) retry (elem_saved::save)
              else (* Found matching offer *)
(*                 let _ = Printf.printf "found matching offer!\n" in *)
                let new_rx = Reaction.with_offer rx sender_offer in
                let merged = exchange.compose k in
                match merged.try_react a new_rx offer with
                | Retry -> try_from (Bag.pop incoming) true (elem_saved::save)
                | Block | BlockAndRetry -> try_from (Bag.pop incoming) retry (elem_saved::save)
                | v ->
(*                  print_endline "AQUI !!!!";*)
                  repush_offer save v)
      in
      ( begin
          match offer with
          | Some offer (* when (not k.may_sync) *) ->
(*               Printf.printf "[%d,%s] pushing offer %d\n"  *)
(*                 (Sched.get_tid ()) name @@ Offer.get_id offer; *)
              Bag.push outgoing (mk_message a rx k offer)
          | _ -> ()
        end;
(*        print_endline (Printf.sprintf "[%d,%s] checking..\n" (Sched.get_tid()) name);*)
        let rec clean_until b =
          match Bag.pop b with
          |Some(v) as out ->
            if message_is_active v then
              try_from out false []
            else
              clean_until b
          |None -> Block
        in clean_until incoming)
    in
    fun ep k ->
      { always_commits = false;
        compose = (fun next -> swap ep (k.compose next));
        try_react = try_react ep k}

  let swap ep = swap ep Reagent.commit
end
