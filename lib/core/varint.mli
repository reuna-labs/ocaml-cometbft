(** Unsigned LEB128 varints.

    This is the integer encoding CometBFT uses for the length prefix of the ABCI
    socket transport: [abci/types/messages.go] writes messages through
    [protoio.NewDelimitedWriter], which is Go's [binary.PutUvarint] followed by
    the marshalled protobuf.

    Note that this is {b not} the Tendermint v0.34 framing, which prefixed
    messages with a length-of-length byte and a big-endian length. CometBFT
    v0.37 replaced that, and also switched the varint from signed to unsigned.
    Documentation describing the older scheme is stale. *)

val max_encoded_length : int
(** [10], the largest number of bytes an unsigned 64-bit varint can occupy, and
    hence the most [decode] will ever consume. *)

val encoded_length : int -> int
(** [encoded_length n] is the number of bytes [encode] writes for [n].
    @raise Invalid_argument if [n] is negative. *)

val encode : Cstruct.t -> int -> int
(** [encode buf n] writes the unsigned varint encoding of [n] at offset 0 of
    [buf] and returns the number of bytes written.

    @raise Invalid_argument
      if [n] is negative or [buf] is shorter than [encoded_length n]. *)

type decoded = {
  value : int;  (** the decoded integer *)
  consumed : int;  (** how many bytes of the input it occupied *)
}

val decode : Cstruct.t -> [ `Ok of decoded | `Need_more | `Overflow ]
(** [decode buf] reads a varint from the front of [buf].

    [`Need_more] means [buf] ends in the middle of a varint and the caller
    should retry once more bytes have arrived -- this is the normal case when
    reading from a stream, not an error.

    [`Overflow] means the encoding does not fit in an OCaml [int] (or runs past
    {!max_encoded_length}), which on a well-behaved connection cannot happen and
    indicates a desynchronised or hostile peer. *)
