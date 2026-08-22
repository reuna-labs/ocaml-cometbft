#!/usr/bin/env bash
#
# Build the ABCI socket server into a real MirageOS/Solo5 unikernel.
#
# This is the strong form of the MirageOS check. test/check-mirage-safe.sh is
# the one-second approximation; this one actually cross-compiles.
#
#   ./test/check-unikernel.sh            # default target: sptmac (macOS)
#   TARGET=spt ./test/check-unikernel.sh # Linux
#
# Requires a switch with the mirage tool, ocaml-solo5 and solo5 (for sptmac,
# the Solo5 fork that provides that target). Set OPAMSWITCH to pick it.
#
# WHY IT BUILDS OUT OF TREE
#
# `mirage configure` drives `opam monorepo lock`, which scans the working
# directory for opam files and treats what it finds as local packages. Run from
# the repository root it would pick up all five cometbft *.opam files, and the
# solve then fails to select the dune ports of logs/fmt/ptime/cmdliner from the
# opam-overlays repository. Building from a scratch directory and consuming
# cometbft through ordinary opam pins avoids that -- and is the more honest
# test, since it exercises the packages as a consumer would get them rather
# than as local directories dune happens to see.
set -euo pipefail

TARGET="${TARGET:-sptmac}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$(mktemp -d)}"

command -v mirage >/dev/null || { echo "no mirage tool on PATH; set OPAMSWITCH to a mirage switch" >&2; exit 2; }

echo "==> pin the unikernel-safe packages (cometbft-unix is deliberately excluded)"
for p in cometbft-proto cometbft cometbft-lwt; do
  opam pin add -y -n -k path "$p" "$REPO" >/dev/null
done
# Pins cache the opam metadata at pin time, so refresh after editing any .opam.
opam update cometbft-proto cometbft cometbft-lwt >/dev/null

echo "==> the dune ports of non-dune dependencies have to be visible"
opam repo add opam-overlays git+https://github.com/dune-universe/opam-overlays.git --rank=2 >/dev/null 2>&1 || true

cp "$REPO/mirage-smoke/config.ml" "$REPO/mirage-smoke/unikernel.ml" "$WORK/"
cd "$WORK"

# Generate the Makefile *before* configuring: `mirage query` rewrites ./dune
# back to its configure-time form, which silently turns `make build` into a
# no-op that still reports success.
mirage query Makefile -t "$TARGET" > Makefile
mirage configure -t "$TARGET"

echo "==> lock"
make lock
echo "==> install host dependencies"
make install-switch
echo "==> pull sources into duniverse"
make pull

# `make lock`/`install-switch` run `mirage query` internally, so re-run
# configure to restore a ./dune that includes dune.build.
mirage configure -t "$TARGET"

echo "==> cross-compile"
make build

IMAGE="dist/cometbft-smoke.$TARGET"
[ -f "$IMAGE" ] || { echo "FAIL: $IMAGE was not produced" >&2; exit 1; }

echo
echo "PASS: $(file -b "$IMAGE")"
solo5-elftool query-abi "$IMAGE" 2>/dev/null || true
echo "image: $WORK/$IMAGE"
