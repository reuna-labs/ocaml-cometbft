## v0.1.0 (unreleased)

First release: an OCaml SDK for ABCI 2.0.

- **Protocol core** (`cometbft`), with no I/O and no scheduler: the
  unsigned-varint length-delimited socket codec, an `App` signature covering
  the sixteen application-implemented ABCI methods, a `Defaults` functor
  mirroring Go's `BaseApplication`, and request dispatch.
- **Both transports**, functorised over `Mirage_flow.S` and routed through the
  same dispatcher so they cannot drift apart: the native ABCI socket transport
  (`cometbft-lwt`) and the `tendermint.abci.ABCI` gRPC service
  (`cometbft-grpc`). They are separate packages so that a socket-only unikernel
  does not link h2, hpack, angstrom and faraday.
- **Unix entry points** (`cometbft-unix`) and a runnable `examples/kvstore`.
- **Generated protobuf types** (`cometbft-proto`) for the `tendermint.abci`
  package, vendored from CometBFT v0.40.0 and committed, so building needs no
  protoc. The ocaml-protoc-plugin *runtime* is vendored too, cutting the
  package's dependencies to `base64` and `ptime`; without that, opam-monorepo
  cannot vendor a unikernel's dependencies at all.
- Verified against a real `cometbft` node over both transports, including
  restart-and-replay through the ABCI handshake (`test/e2e.sh`), and against
  CometBFT's own Go encoder via committed golden wire vectors.
- MirageOS/Solo5 safety is enforced by `test/check-mirage-safe.sh` in CI:
  nothing in the core or transport layers, nor anything in their transitive
  dependency closure, may reach `unix`. `test/check-unikernel.sh` builds the
  real thing; all cometbft code cross-compiles to aarch64 Solo5, though the
  final link currently fails inside Mirage's own runtime -- an empty unikernel
  fails identically. See `mirage-smoke/README.md`.
