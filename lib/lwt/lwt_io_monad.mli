(** Lwt as a {!Cometbft.App.IO}.

    Instantiate {!Cometbft.App.Defaults} and {!Cometbft.Dispatch.Make} with this
    to get an asynchronous application. It is the only monad a MirageOS
    unikernel can use, since MirageOS has no Eio backend. *)

include Cometbft.App.IO with type 'a t = 'a Lwt.t
