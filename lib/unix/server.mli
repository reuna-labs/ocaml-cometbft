(** Running an ABCI application as an ordinary Unix process.

    Supplies the two things {!Cometbft_lwt.Socket_server} deliberately leaves
    out: a concrete flow (via [mirage-flow-unix]) and an accept loop. A MirageOS
    unikernel replaces this module with a few lines against its own [Tcpip]
    stack and reuses everything else unchanged. *)

type address =
  | Tcp of string * int  (** host, port *)
  | Unix_socket of string  (** filesystem path *)

val parse_address : string -> (address, string) result
(** Parse a CometBFT [proxy_app] address.

    Accepts [tcp://host:port], [unix:///path/to.sock], and a bare [host:port]
    (treated as TCP), matching what a node will have in its [config.toml]. *)

val pp_address : Format.formatter -> address -> unit

module Make (A : Cometbft.App.S with type 'a Io.t = 'a Lwt.t) : sig
  val listen : ?backlog:int -> A.t -> address -> unit Lwt.t
  (** [listen app address] serves [app] until the process is killed.

      CometBFT opens four connections to this one listener, so the loop keeps
      accepting and serves each concurrently; see {!Cometbft_lwt.Socket_server}
      for what that means for shared state. A connection ending does not stop
      the listener, because a node that reconnects -- after a restart, say --
      should find the application still there.

      For a Unix socket, a stale file at that path left by a previous run is
      removed before binding. *)
end
