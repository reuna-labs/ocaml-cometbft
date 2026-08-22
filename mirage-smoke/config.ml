(* Mirage configuration for the link check. See README.md: the point is that
   this fails to build if unix ever creeps into cometbft or cometbft-lwt. *)
open Mirage

let main =
  main "Unikernel.Make"
    ~packages:[ package "cometbft"; package "cometbft-lwt" ]
    (stackv4v6 @-> job)

let () = register "cometbft-smoke" [ main $ generic_stackv4v6 default_network ]
