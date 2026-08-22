package main

import (
	"bytes"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"os"

	"github.com/cometbft/cometbft/abci/types"
)

func emitVarints(w *os.File) {
	vals := []uint64{0, 1, 127, 128, 129, 255, 256, 16383, 16384, 2097151,
		2097152, 268435455, 268435456, 2147483647}
	for _, v := range vals {
		buf := make([]byte, binary.MaxVarintLen64)
		n := binary.PutUvarint(buf, v)
		fmt.Fprintf(w, "varint %d %s\n", v, hex.EncodeToString(buf[:n]))
	}
}

// frame writes a Request through CometBFT's own WriteMessage, i.e. exactly what
// a real node puts on an ABCI socket.
func frame(w *os.File, label string, req *types.Request) {
	var b bytes.Buffer
	if err := types.WriteMessage(req, &b); err != nil {
		panic(err)
	}
	fmt.Fprintf(w, "frame %s %s\n", label, hex.EncodeToString(b.Bytes()))
}

func main() {
	w := os.Stdout
	emitVarints(w)

	frame(w, "echo", types.ToRequestEcho("hello abci"))
	frame(w, "flush", types.ToRequestFlush())
	frame(w, "info", types.ToRequestInfo(&types.RequestInfo{
		Version: "1.2.3", BlockVersion: 11, P2PVersion: 8, AbciVersion: "2.0.0",
	}))
	frame(w, "check_tx", types.ToRequestCheckTx(&types.RequestCheckTx{
		Tx: []byte("key=value"), Type: types.CheckTxType_Recheck,
	}))
	frame(w, "commit", types.ToRequestCommit())
	frame(w, "finalize_block", types.ToRequestFinalizeBlock(&types.RequestFinalizeBlock{
		Txs:    [][]byte{[]byte("tx1"), []byte("tx2")},
		Height: 42,
		Hash:   []byte("blockhash"),
	}))
}
