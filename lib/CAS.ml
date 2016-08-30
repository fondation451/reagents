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

type 'a updt = { expect : 'a ; update : 'a }

type 'a state =
  | Idle of 'a
  | InProgress of 'a

and 'a ref = { mutable content : 'a state ;
                       id      : int      }

and t = CAS : 'a ref * 'a updt -> t

let get_id {id; _} = id

let compare_and_swap r x y =
  ( Obj.compare_and_swap_field (Obj.repr r) 0 (Obj.repr x) (Obj.repr y))

let ref x = { content = Idle x           ;
              id      = Oo.id (object end) }

let get r = match r.content with
  | Idle a -> a
  | InProgress a -> a

let cas r u = CAS (r, u)

let is_on_ref (CAS (r1, _)) r2 = r1.id == r2.id

let get_cas_id (CAS ({id;_},_)) = id

let debug s = () (* print_string s *)

let rtm_stats = Array.init 128 (fun _ -> Array.make 8 0)

let rec commit ((CAS (r, { expect ; update })) as cas) =
  let br = Pervasives.ref 0 in
  let dom_id = Domain.self () in
  let body f =
    let s = r.content in
    match s with
    | Idle a when a == expect ->
        if expect != update then f ()
        else true
    | _ -> false
  in
  let opt () = body (fun () ->
    r.content <- Idle update;
    rtm_stats.(dom_id).(0) <- rtm_stats.(dom_id).(0) + 1;
    true)
  in
  let pes s =
    br := 1;
    if (s land 0x2 > 0 || s land 0x4 > 0) then
      (* XAbort_retry *)
      (debug @@ Printf.sprintf "XAbort_retry\n%!";
       rtm_stats.(dom_id).(1) <- rtm_stats.(dom_id).(1) + 1;
       Domain.pause ();
       commit cas)
    else
      (debug @@ Printf.sprintf "XAbort: %d\n%!" s;
       rtm_stats.(dom_id).(2) <- rtm_stats.(dom_id).(2) + 1;
       body (fun () -> compare_and_swap r r.content (Idle update)))
  in
  let res = atomically opt pes in
  if !br = 0 && res then debug @@ Printf.sprintf "RTM success\n%!";
  res

(* Try to acquire a list of CASes and return, in the case of failure, the CASes
 * that must be rolled back. *)
let semicas cases =
  let rec loop log = function
    | [] -> None (* All CASes have been aquired and none must be rolled back.*)
    | (CAS (r, { expect ; _ })) as cas :: xs ->
      let s = r.content in
      match s with
      | Idle a ->
        if a == expect then
          if compare_and_swap r s (InProgress a) then
            (* CAS succeeded, add it to the rollback log and continue with the
             * rest of the CASes. *)
            loop (cas::log) xs
          else Some log (* CAS failed, return the rollback log. *)
        else Some log  (* CAS will fail, ditto. *)
      | InProgress _ ->
        (* This thread lost the race to acquired the CASes. *)
        Some log
  in loop [] cases

(* Only the thread that performed the semicas should be able to rollbwd/fwd.
 * Hence, we don't need to CAS. *)
let rollbwd (CAS (r, _)) =
  match r.content with
  | Idle _      -> ()
  | InProgress x -> r.content <- Idle x

let rollfwd (CAS (r, { update ; _ })) =
  match r.content with
  | Idle _ -> failwith "CAS.kCAS: broken invariant"
  | InProgress x ->  r.content <- Idle update
                    (* we know we have x == expect *)

let rec kCAS_optimistic dom_id = function
  | [] ->
      rtm_stats.(dom_id).(0) <- rtm_stats.(dom_id).(0) + 1;
      true
  | (CAS (r, {expect; update}))::xs ->
      match r.content with
      | Idle a when a == expect ->
          (if expect != update then r.content <- Idle update);
          kCAS_optimistic dom_id xs
      | _ -> xabort 0

let rec kCAS l =
  let dom_id = Domain.self () in
  let res =
    atomically (fun () -> kCAS_optimistic dom_id l) (fun s ->
      if (s land 0x2 > 0 || s land 0x4 > 0) then
        (* XAbort_retry *)
        (debug @@ Printf.sprintf "kCAS: XAbort_retry\n%!";
        rtm_stats.(dom_id).(1) <- rtm_stats.(dom_id).(1) + 1;
        Domain.pause ();
        kCAS l)
      else
        (debug @@ Printf.sprintf "kCAS: XAbort: %d\n%!" s;
        rtm_stats.(dom_id).(2) <- rtm_stats.(dom_id).(2) + 1;
        let l = List.sort (fun c1 c2 ->
                  (get_cas_id c1) - (get_cas_id c2)) l
        in
        match semicas l with
        | None -> List.iter rollfwd l; true
        | Some log -> List.iter rollbwd log; false))
  in
  res

module Sugar : sig
  val ref : 'a -> 'a ref
  val (!) : 'a ref -> 'a
  val (-->) : 'a -> 'a -> 'a updt
  val (<!=) : 'a ref -> 'a updt -> bool
  val (<:=) : 'a ref -> 'a updt -> t
end = struct
  type 'a casupdt = 'a updt
  type 'a casref = 'a ref
  let ref x = ref x
  let (!) r = get r

  let (-->) expect update = { expect ; update }

  let (<:=) = cas
  let (<!=) r u = commit (cas r u)
end

open Sugar

type 'a cas_result = Aborted | Failed | Success of 'a

let try_map r f =
  let s = !r in
  match f s with
  | None -> Aborted
  | Some v ->
      if r <!= s --> v then Success s else Failed

let map r f =
  let b = Backoff.create () in
  let rec loop () =
    match try_map r f with
    | Failed -> (Backoff.once b; loop ())
    | v -> v
  in loop ()

let incr r = ignore @@ map r (fun x -> Some (x + 1))
let decr r = ignore @@ map r (fun x -> Some (x - 1))

let print_stats n =
  for i = 0 to n -1
  do
    Printf.printf "[%d] success=%d retry=%d abort=%d\n"
      i (rtm_stats.(i).(0)) (rtm_stats.(i).(1)) (rtm_stats.(i).(2))
  done
