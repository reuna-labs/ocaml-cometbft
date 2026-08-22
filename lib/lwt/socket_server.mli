(** The native ABCI socket transport.

    CometBFT's default [proxy_app] transport: length-delimited protobuf over a
    plain stream, with no HTTP/2 or gRPC involved. See {!Cometbft.Framing} for
    the wire format.

    {2 Four connections, not one}

    A node opens {b four} separate connections to the same listener -- query,
    snapshot, mempool and consensus, in that order -- and routes different
    methods down each. This module serves a {i single} connection; accepting is
    left to the caller because it is stack-specific, and the caller must be
    prepared for several concurrent calls to {!serve} against one application.

    Application state is therefore shared across connections and must tolerate
    that. CometBFT's own Go server sidesteps the question with a single global
    mutex covering all four; {!serve} is sequential within a connection but does
    not lock across them, so an application that keeps mutable state should
    either be safe under interleaving or take a lock of its own.

    {2 Ordering is not optional}

    Responses must leave in exactly the order the requests arrived, one per
    request, each of the matching kind. CometBFT's client pops the oldest
    outstanding request and compares it with the response; a mismatch raises
    [ErrUnexpectedResponse] and the node deliberately kills itself. {!serve}
    guarantees this by handling one request at a time, so an application handler
    that blocks holds up that connection -- which is the correct trade, and the
    same one Go makes. *)

module Make
    (Flow : Mirage_flow.S)
    (A : Cometbft.App.S with type 'a Io.t = 'a Lwt.t) : sig
  val serve : A.t -> Flow.flow -> unit Lwt.t
  (** [serve app flow] runs the ABCI protocol on [flow] until the peer closes it
      or the stream becomes unusable, then shuts the flow down.

      It does not raise: a read error, a write error, or a malformed length
      prefix is logged to the [cometbft.socket] source and ends the connection,
      because a length-delimited stream cannot be resynchronised once framing is
      lost. Exceptions from application handlers do not reach here at all --
      {!Cometbft.Dispatch} has already turned them into ABCI [Exception]
      responses.

      A node that loses an ABCI connection shuts down, so in practice [serve]
      returning means the node is going away. *)
end
