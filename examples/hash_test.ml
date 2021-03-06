(*
########
Copyright (c) 2017, Nicolas ASSOUAD <nicolas.assouad@ens.fr>
########
*)

module Queue = Lockfree.MSQueue;;
module Hash = Lockfree.Hash;;

let print_usage_and_exit () =
  print_endline @@ "Usage: " ^ Sys.argv.(0) ^ " <num_domains> <num_items>";
  exit(0)
;;

let (num_doms, num_items) =
  if Array.length Sys.argv < 3 then
    print_usage_and_exit ()
  else try
    let a = int_of_string (Sys.argv.(1)) in
    let b = int_of_string (Sys.argv.(2)) in
    (a,b)
  with Failure _ -> print_usage_and_exit ()
;;

let items_per_dom = num_items;;

(*let () = Printf.printf "[%d] items_per_domain = %d\n%!" (Domain.self ()) items_per_dom;;*)

module S = Sched_work_stealing.Make(struct
  let num_domains = num_doms;;
end);;

module Reagents = Reagents.Make(S);;
open Reagents;;

open Printf;;

module type HASH = sig
  type 'a t;;
  val to_string : 'a t -> ('a -> string) -> string;;
  val create : unit -> 'a t;;
  val find : 'a t -> int -> 'a option;;
  val mem : 'a t -> int -> bool;;
  val add : 'a t -> int -> 'a -> unit;;
  val remove : 'a t -> int -> bool;;
end;;

module Benchmark = struct
  let get_mean_sd l =
    let get_mean l = (List.fold_right (fun a v -> a +. v) l 0.) /. (float_of_int @@ List.length l) in
    let mean = get_mean l in
    let sd = get_mean @@ List.map (fun v -> abs_float (v -. mean) ** 2.) l in
    (mean, sd)
  ;;

  let benchmark f n =
    let rec run acc = function
    |0 -> acc
    |n ->
      let t1 = Unix.gettimeofday () in
      let () = f () in
      let d = Unix.gettimeofday () -. t1 in
      run (d::acc) (n-1)
    in
    let r = run [] n in
    get_mean_sd r
  ;;
end;;

module Sync = Reagents_sync.Make(Reagents);;
module CDL  = Sync.Countdown_latch;;

module Test (H : HASH) = struct
  module Cas = Kcas.W1;;

  let gen_elem nb m =
    Random.self_init ();
    let rec loop i out =
      if i < nb then begin
        let new_elem = Random.int m in
        loop (i+1) (new_elem::out)
      end else
        out
    in loop 0 []
  ;;

  let split_list l n =
    let out = Array.init n (fun i -> []) in
    let rec loop l i =
      match l with
      |h::t -> out.(i mod n) <- (h::(out.(i mod n))); loop t (i+1)
      |[] -> Array.to_list out
    in loop l 0
  ;;

  let insert_hash t l =
    let rec loop l =
      match l with
      |v::tl -> H.add t v v; loop tl
      |[] -> ()
    in loop l
  ;;

  let elem = gen_elem num_items (num_items * 1000);;
  let ll = split_list elem num_doms;;

  let run () =
    let h = H.create () in
    let b = CDL.create (num_doms) in
    let rec loop ll =
      match ll with
      |l::tl ->
        S.fork (fun () ->
          insert_hash h l;
          run (CDL.count_down b) ());
        loop tl
      |[] -> ()
    in loop ll;
    run (CDL.await b) ()
  ;;
end;;

let main () =
  let n = 10 in
  let module M = Test(Hash) in
  let (m,sd) = Benchmark.benchmark (fun () -> M.run ()) n in
  (*printf "Hand-written Lockfree.MSQueue: mean = %f, sd = %f tp=%f\n%!" m sd (float_of_int num_items /. m)*)
  print_endline (sprintf "%f" m)
;;


let () = while true do S.run main done;;
