# ocaml-cometbft

An OCaml SDK for **ABCI 2.0**, the interface CometBFT uses to talk to the
application whose state machine it replicates. Write your chain's state machine
in OCaml and run it behind a CometBFT consensus node.

There was previously no up-to-date OCaml binding for the modern ABCI
specification, so building an app-chain in OCaml meant hand-writing the wire
protocol. This library provides it.

## Status

Public, unaudited `v0.1.0-alpha2`: a stock `cometbft` node drives the example
application to consensus over **both** transports, including
restart-and-replay. See `test/e2e.sh`. Do not use this alpha as an unaudited
production consensus boundary.
See [SECURITY.md](SECURITY.md) for private reporting and the review boundary.

## Install

```sh
opam repository add reuna https://github.com/reuna-labs/opam-repository.git
opam update
opam install cometbft-unix.0.1.0~alpha2
```

The package and its protobuf/flow siblings come from checksum-pinned public
release archives; no development pins are required.

## Your first ABCI application

Include `Cometbft.App.Defaults` and override only what you care about. What you
leave out behaves as CometBFT's own `BaseApplication` would, so this is already
a working chain that produces empty blocks:

```ocaml
module Abci = Cometbft_proto.Types.Tendermint.Abci

module App = struct
  type t = { mutable store : (string * string) list }

  module Io = Cometbft_lwt.Lwt_io_monad

  include Cometbft.App.Defaults (struct
    type nonrec t = t
    module Io = Io
  end)

  let finalize_block st (req : Abci.RequestFinalizeBlock.t) =
    let tx_results =
      List.map
        (fun tx ->
          (* apply tx to st ... *)
          Abci.ExecTxResult.make ~code:Cometbft.App.code_ok ())
        req.txs
    in
    Lwt.return (Abci.ResponseFinalizeBlock.make ~tx_results ())
end

module Server = Cometbft_unix.Server.Make (App)

let () =
  Lwt_main.run
    (Server.listen { store = [] } (Cometbft_unix.Server.Tcp ("127.0.0.1", 26658)))
```

Then point a node at it:

```sh
cometbft init --home ~/.cometbft-dev
cometbft node --home ~/.cometbft-dev --proxy_app=tcp://127.0.0.1:26658
```

A complete version is in `examples/kvstore/`.

## On MirageOS

The servers are functors over `Mirage_flow.S`, so a unikernel supplies its own
stack and reuses everything else:

```ocaml
module Make (Stack : Tcpip.Stack.V4V6) = struct
  module Server = Cometbft_lwt.Socket_server.Make (Stack.TCP) (App)

  let start stack =
    Stack.TCP.listen (Stack.tcp stack) ~port:26658 (Server.serve app);
    Stack.listen stack
end
```

`test/check-mirage-safe.sh` fails the build if `unix` ever reaches the core or
transport packages, or anything in their dependency closure -- it runs in about
a second, on every push. `test/check-unikernel.sh` does the real thing and
cross-compiles `mirage-smoke/` for Solo5; see `mirage-smoke/README.md` for its
current status and for two sharp edges in the mirage tooling.

## Things that will bite you

These are properties of ABCI, not of this library, and getting them wrong
produces failures that look like consensus bugs:

- **`finalize_block` must not persist; `commit` must.** CometBFT replays from
  the height `info` reports, so persisting early makes crash recovery
  incorrect.
- **Return one `ExecTxResult` per transaction** from `finalize_block`. A length
  mismatch is rejected outright.
- **Do not raise to reject a transaction.** An exception becomes an ABCI
  `Exception` response, which *halts the node*. Rejection is a non-zero `code`
  in an ordinary response.
- **`prepare_proposal` / `process_proposal` run once per round**, possibly many
  times at one height. Speculative work needs a discardable candidate state.
- **Vote extensions are off by default.** `extend_vote` never fires unless
  `consensus_params.feature.vote_extensions_enable_height` is above zero in
  `genesis.json`.
- **Only enable `mempool.type = "app"`** once `insert_tx` and `reap_txs` are
  implemented.
- **In gRPC mode, `proxy_app` takes a bare `host:port`**, not `tcp://host:port`
  — CometBFT passes it straight to `grpc.Dial`, which rejects the scheme.

## Transports

Both are supported and both are covered by the end-to-end test:

```sh
./test/e2e.sh                 # native ABCI socket (CometBFT's default)
TRANSPORT=grpc ./test/e2e.sh  # gRPC
```

The gRPC transport currently needs a pinned `ocaml-grpc`, because the released
`grpc.0.2.0` caps `h2` below 0.13.0 while the Mirage-capable `h2` is 0.13.0.
The fix is on the project's `main` branch but unreleased:

```sh
G=git+https://github.com/dialohq/ocaml-grpc.git#b629b55fc15964c5e9455058725519d3f7cfc9a7
opam pin add grpc "$G" && opam pin add grpc-lwt "$G"
```

The socket transport has no such dependency, which is why it is the default.

## Design

Four packages, split so that a MirageOS/Solo5 unikernel links only code that
cannot depend on `unix`:

| Package | Contents |
|---|---|
| `cometbft-proto` | Generated protobuf types (committed; no protoc needed to build) |
| `cometbft` | Pure protocol core: framing codec, `App` signature, dispatch. No I/O |
| `cometbft-lwt` | The ABCI socket transport, functorised over `Mirage_flow.S` |
| `cometbft-grpc` | The `tendermint.abci.ABCI` gRPC service, over `H2.Reqd.t` |
| `cometbft-unix` | Unix entry points for both transports |

gRPC is a separate package on purpose: an application speaking only the native
socket transport -- CometBFT's default, and what a unikernel most likely wants
-- should not have to link h2, hpack, angstrom and faraday.

`cometbft-lwt` is the MirageOS package too: because it is functorised over
`Mirage_flow.S`, a unikernel instantiates it with its `Tcpip` stack and
`cometbft-unix` instantiates the same functor with `mirage-flow-unix`.

Lwt rather than Eio is a constraint, not a preference: MirageOS has no Eio
backend.

## Protocol version

Generated from the **`tendermint.abci`** proto package, vendored at CometBFT
**v0.40.0** (`proto/`).

This is deliberate and worth stating, because the naming is a trap. CometBFT's
actively-developed line is v0.38.x/v0.39.x/v0.40.x and still uses
`tendermint.abci`; the `cometbft.abci.v1` package belongs to the separate v1.x
branch, which is *not* an ancestor of v0.40 and is **wire-incompatible** in at
least two places (`CheckTx.type` moved from field 2 to 3 with a renumbered
enum, and `ValidatorUpdate` replaced `pub_key` with `pub_key_bytes` /
`pub_key_type`).

The v0.40 protos are a strict superset of v0.38.26 -- the only additions are
`InsertTx`/`ReapTxs` and two `PublicKey` variants -- so one generated set serves
v0.38, v0.39 and v0.40 nodes.

## Regenerating the protobuf bindings

The generated OCaml under `lib/proto/` is committed, so consumers need neither
`protoc` nor the plugin. To refresh after bumping the vendored protos:

```sh
opam install ocaml-protoc-plugin
./gen.sh
```

## Licence

ISC. See `LICENSE.md`.
