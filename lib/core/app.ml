module Abci = Cometbft_proto.Types.Tendermint.Abci

module type IO = sig
  type +'a t

  val return : 'a -> 'a t
  val bind : 'a t -> ('a -> 'b t) -> 'b t
  val catch : (unit -> 'a t) -> (exn -> 'a t) -> 'a t
end

module Identity = struct
  type 'a t = 'a

  let return x = x
  let bind x f = f x
  let catch f handler = try f () with e -> handler e
end

module type BASE = sig
  module Io : IO

  type t
end

module type S = sig
  include BASE

  val info : t -> Abci.RequestInfo.t -> Abci.ResponseInfo.t Io.t
  val query : t -> Abci.RequestQuery.t -> Abci.ResponseQuery.t Io.t
  val check_tx : t -> Abci.RequestCheckTx.t -> Abci.ResponseCheckTx.t Io.t
  val insert_tx : t -> Abci.RequestInsertTx.t -> Abci.ResponseInsertTx.t Io.t
  val reap_txs : t -> Abci.RequestReapTxs.t -> Abci.ResponseReapTxs.t Io.t
  val init_chain : t -> Abci.RequestInitChain.t -> Abci.ResponseInitChain.t Io.t

  val prepare_proposal :
    t -> Abci.RequestPrepareProposal.t -> Abci.ResponsePrepareProposal.t Io.t

  val process_proposal :
    t -> Abci.RequestProcessProposal.t -> Abci.ResponseProcessProposal.t Io.t

  val extend_vote :
    t -> Abci.RequestExtendVote.t -> Abci.ResponseExtendVote.t Io.t

  val verify_vote_extension :
    t ->
    Abci.RequestVerifyVoteExtension.t ->
    Abci.ResponseVerifyVoteExtension.t Io.t

  val finalize_block :
    t -> Abci.RequestFinalizeBlock.t -> Abci.ResponseFinalizeBlock.t Io.t

  val commit : t -> Abci.RequestCommit.t -> Abci.ResponseCommit.t Io.t

  val list_snapshots :
    t -> Abci.RequestListSnapshots.t -> Abci.ResponseListSnapshots.t Io.t

  val offer_snapshot :
    t -> Abci.RequestOfferSnapshot.t -> Abci.ResponseOfferSnapshot.t Io.t

  val load_snapshot_chunk :
    t ->
    Abci.RequestLoadSnapshotChunk.t ->
    Abci.ResponseLoadSnapshotChunk.t Io.t

  val apply_snapshot_chunk :
    t ->
    Abci.RequestApplySnapshotChunk.t ->
    Abci.ResponseApplySnapshotChunk.t Io.t
end

let code_ok = 0

module Defaults (B : BASE) = struct
  let ret x = B.Io.return x
  let info _ _ = ret (Abci.ResponseInfo.make ())
  let query _ _ = ret (Abci.ResponseQuery.make ~code:code_ok ())
  let check_tx _ _ = ret (Abci.ResponseCheckTx.make ~code:code_ok ())
  let insert_tx _ _ = ret (Abci.ResponseInsertTx.make ~code:code_ok ())
  let reap_txs _ _ = ret (Abci.ResponseReapTxs.make ())
  let init_chain _ _ = ret (Abci.ResponseInitChain.make ())

  (* Pass the proposed transactions straight through, but honour max_tx_bytes:
     CometBFT rejects a proposal larger than it asked for. Same truncation rule
     as Go's BaseApplication -- stop at the first transaction that would take
     the running total over the limit, rather than skipping it and continuing. *)
  let prepare_proposal _ (req : Abci.RequestPrepareProposal.t) =
    let limit = req.max_tx_bytes in
    let rec take acc total = function
      | [] -> List.rev acc
      | tx :: rest ->
          let total = Int64.add total (Int64.of_int (Bytes.length tx)) in
          if Int64.compare total limit > 0 then List.rev acc
          else take (tx :: acc) total rest
    in
    ret (Abci.ResponsePrepareProposal.make ~txs:(take [] 0L req.txs) ())

  (* ACCEPT, not the enum's zero value: UNKNOWN is an error to CometBFT. *)
  let process_proposal _ _ =
    ret
      (Abci.ResponseProcessProposal.make
         ~status:Abci.ResponseProcessProposal.ProposalStatus.ACCEPT ())

  let extend_vote _ _ = ret (Abci.ResponseExtendVote.make ())

  let verify_vote_extension _ _ =
    ret
      (Abci.ResponseVerifyVoteExtension.make
         ~status:Abci.ResponseVerifyVoteExtension.VerifyStatus.ACCEPT ())

  (* Exactly one result per transaction; a length mismatch is rejected. *)
  let finalize_block _ (req : Abci.RequestFinalizeBlock.t) =
    let tx_results =
      List.map (fun _ -> Abci.ExecTxResult.make ~code:code_ok ()) req.txs
    in
    ret (Abci.ResponseFinalizeBlock.make ~tx_results ())

  let commit _ _ = ret (Abci.ResponseCommit.make ())
  let list_snapshots _ _ = ret (Abci.ResponseListSnapshots.make ())
  let offer_snapshot _ _ = ret (Abci.ResponseOfferSnapshot.make ())
  let load_snapshot_chunk _ _ = ret (Abci.ResponseLoadSnapshotChunk.make ())
  let apply_snapshot_chunk _ _ = ret (Abci.ResponseApplySnapshotChunk.make ())
end
