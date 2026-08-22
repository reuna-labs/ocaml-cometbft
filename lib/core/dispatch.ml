module Abci = Cometbft_proto.Types.Tendermint.Abci

let exception_response error =
  `Exception (Abci.ResponseException.make ~error ())

module Make (A : App.S) = struct
  let ( let* ) = A.Io.bind

  (* Each branch pairs a request payload with the response constructor of the
     same kind. Keeping the wrapping here, rather than in the handlers, is what
     makes it impossible for an application to answer a CheckTx with a Commit --
     a mismatch CometBFT treats as fatal. *)
  let route app (request : Abci.Request.t) : Abci.Response.t A.Io.t =
    match request with
    (* Answered by the library, exactly as CometBFT's Go server does. *)
    | `Echo message -> A.Io.return (`Echo (Abci.ResponseEcho.make ~message ()))
    | `Flush () -> A.Io.return (`Flush (Abci.ResponseFlush.make ()))
    (* Info / query connection. *)
    | `Info r ->
        let* v = A.info app r in
        A.Io.return (`Info v)
    | `Query r ->
        let* v = A.query app r in
        A.Io.return (`Query v)
    (* Mempool connection. *)
    | `Check_tx r ->
        let* v = A.check_tx app r in
        A.Io.return (`Check_tx v)
    | `Insert_tx r ->
        let* v = A.insert_tx app r in
        A.Io.return (`Insert_tx v)
    | `Reap_txs r ->
        let* v = A.reap_txs app r in
        A.Io.return (`Reap_txs v)
    (* Consensus connection. *)
    | `Init_chain r ->
        let* v = A.init_chain app r in
        A.Io.return (`Init_chain v)
    | `Prepare_proposal r ->
        let* v = A.prepare_proposal app r in
        A.Io.return (`Prepare_proposal v)
    | `Process_proposal r ->
        let* v = A.process_proposal app r in
        A.Io.return (`Process_proposal v)
    | `Extend_vote r ->
        let* v = A.extend_vote app r in
        A.Io.return (`Extend_vote v)
    | `Verify_vote_extension r ->
        let* v = A.verify_vote_extension app r in
        A.Io.return (`Verify_vote_extension v)
    | `Finalize_block r ->
        let* v = A.finalize_block app r in
        A.Io.return (`Finalize_block v)
    | `Commit r ->
        let* v = A.commit app r in
        A.Io.return (`Commit v)
    (* Snapshot connection. *)
    | `List_snapshots r ->
        let* v = A.list_snapshots app r in
        A.Io.return (`List_snapshots v)
    | `Offer_snapshot r ->
        let* v = A.offer_snapshot app r in
        A.Io.return (`Offer_snapshot v)
    | `Load_snapshot_chunk r ->
        let* v = A.load_snapshot_chunk app r in
        A.Io.return (`Load_snapshot_chunk v)
    | `Apply_snapshot_chunk r ->
        let* v = A.apply_snapshot_chunk app r in
        A.Io.return (`Apply_snapshot_chunk v)
    (* A conforming node never sends this; a desynchronised or hostile one
       might, and silently succeeding would be worse than saying so. *)
    | `not_set ->
        A.Io.return (exception_response "received a Request with no value set")

  let handle app request =
    A.Io.catch
      (fun () -> route app request)
      (fun exn -> A.Io.return (exception_response (Printexc.to_string exn)))
end
