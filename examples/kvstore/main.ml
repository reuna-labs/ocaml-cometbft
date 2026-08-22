(* A key/value ABCI application, in the spirit of CometBFT's own kvstore.

   Transactions are "key=value", or a bare "key" meaning key=key. State lives
   in memory: this is a demonstration of the protocol, not a database. Losing
   it on restart is deliberate and is itself worth exercising -- the node then
   replays from genesis through the ABCI handshake, which is the path most
   likely to be subtly wrong in a new SDK.

   Note what it does NOT do: app_hash here is a cheap fingerprint of the state,
   not a Merkle commitment, so it proves nothing to a light client. Computing a
   real one is the application's job and is out of scope for the SDK. *)

module Abci = Cometbft_proto.Types.Tendermint.Abci

let src = Logs.Src.create "kvstore"

module Log = (val Logs.src_log src : Logs.LOG)

(* ------------------------------------------------------------------- state *)

module Store = Map.Make (String)

type t = {
  mutable committed : string Store.t;
      (** Durable as far as the protocol is concerned: what [commit] has
          accepted, and what [query] answers from. *)
  mutable pending : string Store.t;
      (** Where [finalize_block] writes. Kept separate because [finalize_block]
          must not persist -- only [commit] may. *)
  mutable height : int64;
  mutable app_hash : string;
}

let create () =
  { committed = Store.empty; pending = Store.empty; height = 0L; app_hash = "" }

(* A deterministic 64-bit fingerprint (FNV-1a) over the sorted key/value pairs.
   Every validator must arrive at the same bytes for the same state, which is
   all that is needed to keep a chain live; it is emphatically not a Merkle
   root. Dependency-free on purpose, so the example pulls in no crypto. *)
let fingerprint store =
  let fnv_offset = 0xcbf29ce484222325L and fnv_prime = 0x100000001b3L in
  let hash =
    Store.fold
      (fun key value acc ->
        let mix acc s =
          String.fold_left
            (fun acc c ->
              Int64.mul
                (Int64.logxor acc (Int64.of_int (Char.code c)))
                fnv_prime)
            acc s
        in
        mix (mix acc key) value)
      store fnv_offset
  in
  String.init 8 (fun i ->
      Char.chr
        (Int64.to_int
           (Int64.logand (Int64.shift_right_logical hash (8 * (7 - i))) 0xFFL)))

let parse_tx tx =
  let tx = Bytes.to_string tx in
  match String.index_opt tx '=' with
  | Some i ->
      (String.sub tx 0 i, String.sub tx (i + 1) (String.length tx - i - 1))
  | None -> (tx, tx)

(* --------------------------------------------------------------- the app -- *)

module App = struct
  type nonrec t = t

  module Io = Cometbft_lwt.Lwt_io_monad

  include Cometbft.App.Defaults (struct
    type nonrec t = t

    module Io = Io
  end)

  (* The handshake. CometBFT compares these against its own store to decide how
     much to replay; reporting a height we have not actually committed would
     silently skip blocks. *)
  let info st _ =
    Log.info (fun m -> m "Info: height=%Ld" st.height);
    Lwt.return
      (Abci.ResponseInfo.make ~data:"ocaml-kvstore" ~version:"0.1.0"
         ~last_block_height:st.height
         ~last_block_app_hash:(Bytes.of_string st.app_hash)
         ())

  (* Admission control only. Rejecting here keeps a transaction out of the
     mempool; it is not a place to mutate state, since CheckTx runs against a
     speculative view and may be re-run. *)
  let check_tx _ (req : Abci.RequestCheckTx.t) =
    let tx = Bytes.to_string req.tx in
    let code = if String.length tx = 0 then 1 else Cometbft.App.code_ok in
    Lwt.return (Abci.ResponseCheckTx.make ~code ())

  let init_chain st _ =
    Log.info (fun m -> m "InitChain");
    st.pending <- st.committed;
    Lwt.return
      (Abci.ResponseInitChain.make ~app_hash:(Bytes.of_string st.app_hash) ())

  (* Execute the decided block. Writes go to [pending] only; see [commit]. One
     ExecTxResult per transaction, in order -- CometBFT rejects any other
     length. *)
  let finalize_block st (req : Abci.RequestFinalizeBlock.t) =
    st.pending <- st.committed;
    let tx_results =
      List.map
        (fun tx ->
          let key, value = parse_tx tx in
          st.pending <- Store.add key value st.pending;
          Abci.ExecTxResult.make ~code:Cometbft.App.code_ok ())
        req.txs
    in
    st.height <- req.height;
    let app_hash = fingerprint st.pending in
    Log.info (fun m ->
        m "FinalizeBlock: height=%Ld txs=%d" req.height (List.length req.txs));
    Lwt.return
      (Abci.ResponseFinalizeBlock.make ~tx_results
         ~app_hash:(Bytes.of_string app_hash) ())

  (* The persistence point. A real application flushes to disk here, before
     returning -- everything after this must survive a crash. *)
  let commit st _ =
    st.committed <- st.pending;
    st.app_hash <- fingerprint st.committed;
    Lwt.return (Abci.ResponseCommit.make ())

  let query st (req : Abci.RequestQuery.t) =
    let key = Bytes.to_string req.data in
    let response =
      match Store.find_opt key st.committed with
      | Some value ->
          Abci.ResponseQuery.make ~code:Cometbft.App.code_ok
            ~key:(Bytes.of_string key) ~value:(Bytes.of_string value)
            ~height:st.height ~log:"found" ()
      | None ->
          Abci.ResponseQuery.make ~code:1 ~key:(Bytes.of_string key)
            ~height:st.height ~log:"not found" ()
    in
    Lwt.return response
end

(* ------------------------------------------------------------------ main -- *)

module Socket_server = Cometbft_unix.Server.Make (App)
module Grpc_server = Cometbft_unix.Grpc_listener.Make (App)

let usage () =
  prerr_endline
    "usage: main [--addr tcp://127.0.0.1:26658] [--transport socket|grpc]\n\n\
     Serves an ABCI key/value application. Point a CometBFT node at it with\n\
    \  cometbft node --proxy_app=tcp://127.0.0.1:26658\n\n\
     Use --transport grpc only if the node's config.toml sets abci = \"grpc\";\n\
     the default there is the socket transport.";
  exit 2

let () =
  let addr = ref "tcp://127.0.0.1:26658" in
  let transport = ref `Socket in
  let rec parse = function
    | [] -> ()
    | "--addr" :: value :: rest ->
        addr := value;
        parse rest
    | "--transport" :: "socket" :: rest ->
        transport := `Socket;
        parse rest
    | "--transport" :: "grpc" :: rest ->
        transport := `Grpc;
        parse rest
    | ("-h" | "--help") :: _ -> usage ()
    | _ -> usage ()
  in
  parse (List.tl (Array.to_list Sys.argv));
  Logs.set_reporter (Logs_fmt.reporter ());
  Logs.set_level (Some Logs.Info);
  match Cometbft_unix.Server.parse_address !addr with
  | Error e ->
      prerr_endline ("bad address: " ^ e);
      exit 2
  | Ok address ->
      let state = create () in
      Lwt_main.run
        (match !transport with
        | `Socket -> Socket_server.listen state address
        | `Grpc -> Grpc_server.listen state address)
