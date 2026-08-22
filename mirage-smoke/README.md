# MirageOS link check

This is not a functional test. It exists so that the MirageOS/Solo5 requirement
is enforced by a compiler rather than by good intentions.

`unikernel.ml` instantiates the ABCI socket server over a `Tcpip` stack, which
is only possible if `cometbft` and `cometbft-lwt` are genuinely free of `unix`.

## Building it

Use `../test/check-unikernel.sh`, which wraps the whole flow:

```sh
OPAMSWITCH=<a mirage switch> ./test/check-unikernel.sh          # sptmac
OPAMSWITCH=<a mirage switch> TARGET=spt ./test/check-unikernel.sh
```

It deliberately builds in a scratch directory rather than here. Two things make
the obvious approach fail, both worth knowing before hand-rolling the commands:

- **`opam monorepo lock` scans the working directory for opam files.** Run from
  the repository root it finds all five `cometbft*.opam`, treats them as local
  packages, and then cannot select the dune ports of `logs`, `fmt`, `ptime` and
  `cmdliner` from `opam-overlays`; the lock fails with "these dependencies
  don't use dune as their build system". Building out of tree, against ordinary
  opam pins, avoids it -- and tests the packages the way a consumer gets them.
- **`mirage query` rewrites `./dune` back to its configure-time form**, which
  includes only `dune.config`. If you run it after `mirage configure`, then
  `make build` quietly builds nothing and still prints "Your unikernel binary is
  now ready". Generate the Makefile first, and re-run `mirage configure` last.

The `unix` target is deliberately *not* the one to trust: it would happily link
the thing we are trying to forbid.

## Status: cross-compiles, does not yet link

As of 2026-08-21, against the local `solo5` 0.12.0 / `ocaml-solo5` 1.3.1 /
`mirage` 4.11.1 forks:

- **Everything in this repository cross-compiles.** `cometbft.cmxa`,
  `cometbft_proto.cmxa` and `cometbft_lwt.cmxa` are all produced as ELF 64-bit
  ARM aarch64 objects for the `sptmac` target.
- **The final link fails in Mirage's own runtime**, with undefined references to
  `mirage_trim_allocation`, `mirage_memory_*`, `caml_get_monotonic_time` and
  `fstat`.

That failure is not ours: **an empty unikernel** -- `let start _stack =
Lwt.return_unit`, with no cometbft dependency at all -- fails to link with the
identical errors. The symbols are defined in `mirage-solo5`'s
`lib/bindings/clock_stubs.c` and `lib/bindings/main.c`, and
`libmirage-solo5_bindings.a` *is* built; it simply is not handed to the linker.
The likely cause is a skew between the upstream `mirage-solo5 0.10.0` that
opam-monorepo vendors and the locally forked `solo5`/`ocaml-solo5` in the
switch, since there is no local `mirage-solo5` fork to pin.

So: run this script again once that is resolved. Until then,
`../test/check-mirage-safe.sh` is what actually guards the constraint on every
build -- it verifies that none of the unikernel-linkable libraries, nor
anything in their transitive dependency closure, touches `unix`.
