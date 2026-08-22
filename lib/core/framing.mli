(** The ABCI socket transport's length-delimited framing.

    Each message on the wire is an unsigned varint byte-length followed by that
    many bytes of marshalled protobuf -- CometBFT's [WriteMessage] in
    [abci/types/messages.go], which delegates to [protoio.NewDelimitedWriter].
    gRPC does its own framing, so none of this applies there.

    {!t} is an incremental decoder: feed it whatever bytes arrived and pull off
    whole frames until it asks for more. It performs no I/O, so the same decoder
    drives a Unix socket and a Mirage flow. *)

val max_frame_length : int
(** [Int32.max_int], CometBFT's [maxMsgSize]. Frames claiming to be longer are
    rejected rather than allocated for. *)

val encode : Cstruct.t -> Cstruct.t
(** [encode payload] is [payload] with its varint length prefix prepended, ready
    to write. The payload is copied.

    @raise Invalid_argument if [payload] is longer than {!max_frame_length}. *)

type t

val create : unit -> t

val feed : t -> Cstruct.t -> unit
(** [feed t chunk] adds freshly-read bytes to [t].

    [t] takes ownership of [chunk]: the payloads {!next} returns are views into
    it, not copies, so the caller must not mutate or reuse [chunk] afterwards.
    That suits both transports, since [Mirage_flow.read] and the Unix reader
    both hand back a freshly allocated buffer each time. *)

val next : t -> [ `Message of Cstruct.t | `Need_more | `Error of string ]
(** [next t] pops the oldest complete frame's payload.

    [`Need_more] is the ordinary "nothing buffered yet" answer, not a failure.
    [`Error] means the stream is unusable -- a length prefix that overflows or
    exceeds {!max_frame_length} -- and the connection should be dropped, since
    there is no way to resynchronise a length-delimited stream.

    Drive it in a loop until it returns something other than [`Message]. *)

val pending : t -> int
(** Bytes buffered but not yet forming a complete frame. Exposed for tests and
    diagnostics. *)
