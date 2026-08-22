(** Serving the ABCI gRPC service from a Unix process.

    Supplies the HTTP/2 runtime that {!Cometbft_grpc.Grpc_server} deliberately
    leaves to the caller, using [h2-lwt-unix]. A MirageOS unikernel does the
    same thing with [H2_mirage.Server(Flow)] instead, reusing the same handler.

    Use this when the node is configured with [abci = "grpc"] in [config.toml].
    The default is the socket transport, served by {!Cometbft_unix.Server}. *)

module Make (A : Cometbft.App.S with type 'a Io.t = 'a Lwt.t) : sig
  val listen : ?backlog:int -> A.t -> Server.address -> unit Lwt.t
  (** [listen app address] serves the ABCI gRPC service until killed.

      Only [Server.Tcp] addresses are supported: gRPC over a Unix domain socket
      is not something CometBFT will ask for. *)
end
