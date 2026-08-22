#!/usr/bin/env bash
#
# Enforce the MirageOS/Solo5 constraint: cometbft-proto, cometbft, cometbft-lwt
# and cometbft-grpc must not reach `unix`, directly or transitively. Only
# cometbft-unix may.
#
# This is the cheap version of the check. The thorough one is building
# mirage-smoke/ for a Solo5 target, which needs the mirage tool installed; this
# runs in a second and catches essentially the same mistake, so it belongs in
# CI on every push.
set -euo pipefail

cd "$(dirname "$0")/.."

fail=0

# 1. No module of ours may import Unix directly.
for lib in cometbft_proto cometbft cometbft_lwt cometbft_grpc; do
  cma="$(find _build/default/lib -name "$lib.cma" | head -1)"
  if [ -z "$cma" ]; then
    echo "SKIP $lib (not built; run dune build first)" >&2
    continue
  fi
  if ocamlobjinfo "$cma" | grep -qE '^[[:space:]]+[0-9a-f]+[[:space:]]+Unix$'; then
    echo "FAIL: $lib imports Unix" >&2
    fail=1
  else
    echo "ok: $lib does not import Unix"
  fi
done

# 2. Nor may anything they depend on. A library can be free of Unix itself and
#    still drag it in through a dependency, which is the failure this catches.
check_closure() { # $1 = label, rest = findlib packages
  local label="$1"; shift
  if ocamlfind query -recursive -p-format "$@" 2>/dev/null | grep -qx unix; then
    echo "FAIL: $label pulls in unix" >&2
    fail=1
  else
    echo "ok: $label dependency closure is free of unix"
  fi
}

# cometbft-lwt is the one a socket-only unikernel links, so it is kept clear of
# the HTTP/2 stack as well as of unix -- check it separately from cometbft-grpc
# so that a stray h2 dependency creeping back in is visible.
check_closure "cometbft-lwt" base64 ptime cstruct logs fmt lwt mirage-flow
check_closure "cometbft-grpc" base64 ptime logs fmt lwt h2 grpc grpc-lwt

if ocamlfind query -recursive -p-format base64 ptime cstruct logs fmt lwt mirage-flow 2>/dev/null | grep -qxE "h2|hpack|angstrom|faraday"; then
  echo "FAIL: the socket-only closure has grown an HTTP/2 dependency" >&2
  fail=1
else
  echo "ok: socket-only closure carries no HTTP/2 stack"
fi

# 3. And cometbft-unix should still be the one place that does use it, so a
#    silent loss of Unix support shows up too.
cma="$(find _build/default/lib -name cometbft_unix.cma | head -1)"
if [ -n "$cma" ] && ! ocamlobjinfo "$cma" | grep -qE '^[[:space:]]+[0-9a-f]+[[:space:]]+Unix$'; then
  echo "warning: cometbft_unix no longer imports Unix -- is that intended?" >&2
fi

exit $fail
