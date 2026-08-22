(** Routing a decoded ABCI request to the application and back.

    This is where the protocol's shape lives: which requests the library answers
    itself, which reach the application, and what happens when one of them
    raises. It performs no I/O, so it is driven identically by the socket
    server, the gRPC server, and the test suite. *)

module Abci = Cometbft_proto.Types.Tendermint.Abci

val exception_response : string -> Abci.Response.t
(** Build an ABCI [Exception] response.

    Note what this means to CometBFT: on receiving one, the client calls
    [StopForError] and the node shuts down. It is a fatal-error channel, not a
    way to reject a transaction. To reject a transaction, return a normal
    response with a non-zero [code]. *)

module Make (A : App.S) : sig
  val handle : A.t -> Abci.Request.t -> Abci.Response.t A.Io.t
  (** [handle app request] produces the matching response.

      [Echo] and [Flush] are answered here and never reach [app], matching
      CometBFT's own server. [Flush] in particular must be answered promptly and
      in order, since it is the client's barrier signalling that everything
      queued before it has been dealt with.

      An exception escaping an application handler becomes {!exception_response}
      rather than propagating, so that one bad handler cannot silently drop a
      connection mid-stream. A request whose [oneof] is unset -- which a
      conforming node never sends -- likewise yields an exception response.

      The response for a request is always of the corresponding kind. CometBFT's
      client pops the oldest outstanding request and checks the response type
      against it, so a mismatch is fatal to the node. *)
end
