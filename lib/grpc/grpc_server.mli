(** The ABCI service over gRPC.

    CometBFT can be configured with [abci = "grpc"] instead of the default
    socket transport, in which case it speaks ordinary gRPC to
    [tendermint.abci.ABCI]. Each ABCI method is a unary call; there is no
    length-prefix framing here, because gRPC does its own.

    This module produces an [H2.Reqd.t] handler and nothing more. Supplying the
    HTTP/2 runtime is left to the caller, which is what keeps the gRPC transport
    usable from a unikernel: pair it with [h2-mirage]'s [H2_mirage.Server(Flow)]
    on MirageOS, or [h2-lwt-unix] on Unix. Nothing here depends on either.

    {2 How it relates to the socket transport}

    Requests are wrapped into the same [Request] envelope the socket transport
    uses and run through the same {!Cometbft.Dispatch}, so both transports have
    identical semantics -- including which methods the library answers itself.
    The one difference is error reporting. Over a socket, a failing handler
    produces an ABCI [Exception] response; there is no such thing in a typed
    gRPC reply, so it becomes a [Grpc.Status.Internal] instead. *)

val service_name : string
(** ["tendermint.abci.ABCI"] *)

module Make (A : Cometbft.App.S with type 'a Io.t = 'a Lwt.t) : sig
  val service : A.t -> Grpc_lwt.Server.Service.t
  (** The ABCI service with all eighteen methods registered. *)

  val server : A.t -> Grpc_lwt.Server.t
  (** {!service}, routable under {!service_name}. *)

  val handler : A.t -> H2.Reqd.t -> unit
  (** An [H2] request handler, ready to hand to an HTTP/2 server runtime. *)
end
