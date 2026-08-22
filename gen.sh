#!/bin/bash -ex
#
# Regenerate the OCaml protobuf bindings under lib/proto/ from the .proto tree
# vendored in proto/.
#
# The output is COMMITTED to the repository, so building ocaml-cometbft needs
# neither protoc nor this plugin. Only run this after bumping the vendored
# protos (see README.md for which CometBFT tag they came from).
#
# requires: opam install ocaml-protoc-plugin   (and a protoc on PATH)
#
# Flags follow the recipe proven in nethsm's etcd_client, which runs the same
# stack inside a MirageOS unikernel:
#   int64_as_int=false -- ABCI block heights, gas and vote power are genuine
#                         int64 and must not be silently truncated to OCaml's
#                         63-bit int.
#
# We deliberately do NOT pass annot=[@@deriving show], even though etcd_client
# does. Without ppx_deriving wired into the library the attribute is silently
# ignored (etcd_client builds with -w -a, so it never notices), and wiring it in
# would put a ppx and a runtime library into the one package a unikernel is
# guaranteed to link. Keeping cometbft-proto at exactly base64 + ptime is worth
# more than derived printers; Cometbft.Debug provides printers for the messages
# that actually matter when debugging.

cd "$(dirname "$0")"

rm -rf lib/proto/gen
mkdir -p lib/proto/gen/google_types

protoc -I ./proto \
  "--ocaml_out=int64_as_int=false:./lib/proto/gen/" \
  tendermint/abci/types.proto \
  tendermint/crypto/keys.proto \
  tendermint/crypto/proof.proto \
  tendermint/types/params.proto \
  tendermint/types/validator.proto

# The well-known types the ABCI messages reference. Generated into the same
# library (see lib/proto/dune's include_subdirs) so that cross-file references
# such as Timestamp.Google.Protobuf.Timestamp resolve.
protoc --ocaml_out=./lib/proto/gen/google_types/ \
  google/protobuf/timestamp.proto \
  google/protobuf/duration.proto

# gogoproto/gogo.proto is deliberately NOT generated: the ABCI messages use its
# options (nullable, stdtime, customname, ...) but never its message types, and
# every one of those options is a Go-codegen hint that does not affect the wire
# format.
