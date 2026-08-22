#!/usr/bin/env bash
#
# End-to-end test: drive the kvstore example with a real CometBFT node.
#
# This is the test that matters. Everything in `dune test` checks the codec and
# the dispatch table in isolation; only this proves a genuine node will talk to
# us -- handshake, block production, mempool, query, and crash recovery.
#
# Requires a `cometbft` binary on PATH (or in $COMETBFT), plus curl and python3.
#
#   go install github.com/cometbft/cometbft/cmd/cometbft@v0.38.26
#
# Runs the socket transport by default; TRANSPORT=grpc exercises the other one:
#
#   ./test/e2e.sh                 # native ABCI socket (CometBFT's default)
#   TRANSPORT=grpc ./test/e2e.sh  # gRPC
#
set -euo pipefail

COMETBFT="${COMETBFT:-$(command -v cometbft || echo "$HOME/go/bin/cometbft")}"
ADDR="${ADDR:-tcp://127.0.0.1:26658}"
RPC="${RPC:-localhost:26657}"
WORK="$(mktemp -d)"
APP_EXE="$(dirname "$0")/../_build/default/examples/kvstore/main.exe"

[ -x "$COMETBFT" ] || { echo "no cometbft binary; set COMETBFT=<path>" >&2; exit 2; }
[ -x "$APP_EXE" ]  || { echo "build first: dune build examples/kvstore/main.exe" >&2; exit 2; }

app_pid=""; node_pid=""
cleanup() {
  [ -n "$node_pid" ] && kill "$node_pid" 2>/dev/null || true
  [ -n "$app_pid" ]  && kill "$app_pid"  2>/dev/null || true
  wait 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; echo "--- app log ---"; tail -30 "$WORK/app.log" 2>/dev/null; echo "--- node log ---"; tail -30 "$WORK/node.log" 2>/dev/null; exit 1; }

TRANSPORT="${TRANSPORT:-socket}"

start_app() { "$APP_EXE" --addr "$ADDR" --transport "$TRANSPORT" >>"$WORK/app.log" 2>&1 & app_pid=$!; sleep 1; }

# In gRPC mode CometBFT hands proxy_app straight to grpc.Dial, which rejects a
# tcp:// scheme ("too many colons in address"), so the node needs a bare
# host:port. The socket transport wants the scheme. This asymmetry is
# CometBFT's, not ours.
start_node() {
  local target="$ADDR"
  [ "$TRANSPORT" = grpc ] && target="${ADDR#tcp://}"
  "$COMETBFT" start --home "$WORK/home" --proxy_app="$target" >>"$WORK/node.log" 2>&1 & node_pid=$!
}

height() { curl -sf "$RPC/status" | python3 -c 'import sys,json;print(json.load(sys.stdin)["result"]["sync_info"]["latest_block_height"])'; }
app_hash() { curl -sf "$RPC/status" | python3 -c 'import sys,json;print(json.load(sys.stdin)["result"]["sync_info"]["latest_app_hash"])'; }

wait_for_height() { # $1 = target, $2 = seconds
  local target=$1 deadline=$(( SECONDS + $2 ))
  while [ $SECONDS -lt $deadline ]; do
    local h; h="$(height 2>/dev/null || echo 0)"
    [ "${h:-0}" -ge "$target" ] && return 0
    sleep 1
  done
  return 1
}

echo "==> init (transport: $TRANSPORT)"
"$COMETBFT" init --home "$WORK/home" >/dev/null 2>&1
if [ "$TRANSPORT" = grpc ]; then
  # config.toml defaults to abci = "socket"
  sed -i.bak 's/^abci = "socket"/abci = "grpc"/' "$WORK/home/config/config.toml"
fi

echo "==> start app and node"
start_app
start_node

echo "==> blocks are produced (handshake, InitChain, FinalizeBlock, Commit)"
wait_for_height 3 60 || fail "node did not reach height 3"

echo "==> a transaction commits"
result="$(curl -sf "$RPC/broadcast_tx_commit?tx=%22mykey=myvalue%22")"
echo "$result" | python3 -c '
import sys,json
r=json.load(sys.stdin)["result"]
assert r["check_tx"]["code"]==0, "CheckTx rejected: %r" % r["check_tx"]
assert r["tx_result"]["code"]==0, "tx failed: %r" % r["tx_result"]
' || fail "transaction was not accepted"

echo "==> the value is queryable"
curl -sf "$RPC/abci_query?data=%22mykey%22" | python3 -c '
import sys,json,base64
r=json.load(sys.stdin)["result"]["response"]
assert r.get("code",0)==0, "query failed: %r" % r
assert base64.b64decode(r["value"]).decode()=="myvalue", "wrong value: %r" % r
' || fail "query did not return the committed value"

before_hash="$(app_hash)"
before_height="$(height)"
echo "==> committed through height $before_height, app_hash $before_hash"

# The interesting failure mode: restart the application with no state at all.
# CometBFT sees Info.last_block_height = 0 and replays every block through the
# handshake. If our app_hash were non-deterministic, or FinalizeBlock persisted
# when it should not, the node would refuse with an app hash mismatch here.
echo "==> restart the app empty; the node must replay cleanly"
kill "$node_pid"; wait "$node_pid" 2>/dev/null || true; node_pid=""
kill "$app_pid";  wait "$app_pid"  2>/dev/null || true; app_pid=""
start_app
start_node
wait_for_height "$((before_height + 1))" 90 || fail "node did not resume after replay"

if grep -qiE "app hash|mismatch|panic" "$WORK/node.log"; then
  fail "node reported a problem during replay"
fi

echo "==> state was rebuilt by replay"
curl -sf "$RPC/abci_query?data=%22mykey%22" | python3 -c '
import sys,json,base64
r=json.load(sys.stdin)["result"]["response"]
assert base64.b64decode(r["value"]).decode()=="myvalue", "value lost across replay: %r" % r
' || fail "state did not survive replay"

echo
echo "PASS ($TRANSPORT): node reached height $(height); app_hash $(app_hash)"
