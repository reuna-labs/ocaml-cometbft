(** The application interface: what you implement to be a CometBFT chain.

    An ABCI application answers sixteen methods. {!Echo} and {!Flush} are part
    of the protocol but not of this signature -- the server answers them itself,
    exactly as CometBFT's own Go server does, so an application never sees them.

    Everything is parameterised over an {!IO} monad rather than committed to
    Lwt. That keeps this module free of any scheduler, which matters twice over:
    the same code drives a Unix server and a MirageOS unikernel, and the test
    suite can drive dispatch through {!Identity} with no scheduler at all.

    {2 Implementing an application}

    Include {!Defaults} and override only the methods you care about. The
    defaults mirror Go's [BaseApplication], so what you leave out is what
    CometBFT would have done anyway:

    {[
      module My_app = struct
        type t = { mutable store : (string * string) list }

        module Io = Cometbft.App.Identity

        include Cometbft.App.Defaults (struct
          type nonrec t = t

          module Io = Io
        end)

        let check_tx _ (req : Abci.RequestCheckTx.t) = ...
        let finalize_block st req = ...
      end
    ]}

    {2 Obligations the type system cannot express}

    - [finalize_block] must {b not} persist state; [commit] must, before it
      returns. CometBFT replays from the height reported by [info], so an
      application that persists early cannot recover from a crash between the
      two.
    - [info] must report the last {i committed} height and app hash, or the
      handshake will replay the wrong range.
    - [prepare_proposal] and [process_proposal] may be called many times at the
      same height, once per consensus round. Any speculative execution must
      happen in a candidate state that can be discarded; only [finalize_block]
      decides.
    - [process_proposal] and [verify_vote_extension] must be deterministic
      across validators. [prepare_proposal] and [extend_vote] need not be.
    - Returning [REJECT] from [verify_vote_extension] rejects the sender's
      entire precommit. It is a much heavier hammer than it looks.
    - Raising an exception is not a way to reject a transaction. It becomes an
      ABCI [Exception] response, which halts the node. Per-request failures
      belong in the [code] field of a normal response. *)

module Abci = Cometbft_proto.Types.Tendermint.Abci

(** {1 The IO monad} *)

module type IO = sig
  type +'a t

  val return : 'a -> 'a t
  val bind : 'a t -> ('a -> 'b t) -> 'b t

  val catch : (unit -> 'a t) -> (exn -> 'a t) -> 'a t
  (** [catch f handler] runs [f ()] and diverts any exception to [handler].

      This is part of the signature rather than left to the transport because
      {!Cometbft.Dispatch} has to convert an escaping application exception into
      an ABCI [Exception] response, and it cannot do that generically with only
      [return] and [bind]. For Lwt this is [Lwt.catch]. *)
end

module Identity : IO with type 'a t = 'a
(** Direct-style: ['a t = 'a]. For synchronous applications and for tests. *)

(** {1 The application signature} *)

(** What an application must supply besides its handlers. *)
module type BASE = sig
  module Io : IO

  type t
  (** The application's own state, passed to every handler. *)
end

(** The sixteen application-implemented ABCI methods, grouped by the connection
    CometBFT delivers them on. *)
module type S = sig
  include BASE

  (** {2 Info / query connection} *)

  val info : t -> Abci.RequestInfo.t -> Abci.ResponseInfo.t Io.t
  val query : t -> Abci.RequestQuery.t -> Abci.ResponseQuery.t Io.t

  (** {2 Mempool connection} *)

  val check_tx : t -> Abci.RequestCheckTx.t -> Abci.ResponseCheckTx.t Io.t

  val insert_tx : t -> Abci.RequestInsertTx.t -> Abci.ResponseInsertTx.t Io.t
  (** Only reached when the node runs [mempool.type = "app"], where CometBFT
      gossips transactions but delegates storage and ordering here. Added in
      CometBFT v0.39 and absent from the published ABCI spec documents. *)

  val reap_txs : t -> Abci.RequestReapTxs.t -> Abci.ResponseReapTxs.t Io.t
  (** The other half of the app-side mempool; see {!insert_tx}. *)

  (** {2 Consensus connection} *)

  val init_chain : t -> Abci.RequestInitChain.t -> Abci.ResponseInitChain.t Io.t

  val prepare_proposal :
    t -> Abci.RequestPrepareProposal.t -> Abci.ResponsePrepareProposal.t Io.t
  (** Runs on the consensus critical path: the network cannot make progress
      while it does. Exceeding [timeout_propose] makes peers prevote nil. *)

  val process_proposal :
    t -> Abci.RequestProcessProposal.t -> Abci.ResponseProcessProposal.t Io.t

  val extend_vote :
    t -> Abci.RequestExtendVote.t -> Abci.ResponseExtendVote.t Io.t
  (** Never called unless the genesis file sets
      [consensus_params.feature.vote_extensions_enable_height] above zero. If
      you are testing vote extensions and this handler never fires, that is
      almost certainly why. *)

  val verify_vote_extension :
    t ->
    Abci.RequestVerifyVoteExtension.t ->
    Abci.ResponseVerifyVoteExtension.t Io.t

  val finalize_block :
    t -> Abci.RequestFinalizeBlock.t -> Abci.ResponseFinalizeBlock.t Io.t
  (** Must return exactly one [ExecTxResult] per transaction in the request, or
      CometBFT rejects the response. Must not persist; see {!commit}. *)

  val commit : t -> Abci.RequestCommit.t -> Abci.ResponseCommit.t Io.t
  (** Persist before returning. Note that CometBFT holds the mempool lock across
      this call, so an application must not broadcast transactions to its own
      node from here -- that deadlocks. *)

  (** {2 Snapshot connection} *)

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

(** {1 Defaults} *)

(** Spec-compliant do-nothing handlers, mirroring Go's [BaseApplication].

    [include]ing this gives a complete, working application that produces empty
    blocks forever; override what you need. It deliberately does not re-export
    [t] or [Io], so it composes with an [include] without shadowing them.

    Three of these are not merely empty, because empty would be wrong:
    [process_proposal] and [verify_vote_extension] must answer [ACCEPT] (the
    zero value of both enums is [UNKNOWN], which CometBFT treats as an error),
    [prepare_proposal] passes the proposed transactions through while honouring
    [max_tx_bytes], and [finalize_block] returns one success result per
    transaction because a length mismatch is rejected. *)
module Defaults (B : BASE) : sig
  val info : B.t -> Abci.RequestInfo.t -> Abci.ResponseInfo.t B.Io.t
  val query : B.t -> Abci.RequestQuery.t -> Abci.ResponseQuery.t B.Io.t
  val check_tx : B.t -> Abci.RequestCheckTx.t -> Abci.ResponseCheckTx.t B.Io.t

  val insert_tx :
    B.t -> Abci.RequestInsertTx.t -> Abci.ResponseInsertTx.t B.Io.t

  val reap_txs : B.t -> Abci.RequestReapTxs.t -> Abci.ResponseReapTxs.t B.Io.t

  val init_chain :
    B.t -> Abci.RequestInitChain.t -> Abci.ResponseInitChain.t B.Io.t

  val prepare_proposal :
    B.t ->
    Abci.RequestPrepareProposal.t ->
    Abci.ResponsePrepareProposal.t B.Io.t

  val process_proposal :
    B.t ->
    Abci.RequestProcessProposal.t ->
    Abci.ResponseProcessProposal.t B.Io.t

  val extend_vote :
    B.t -> Abci.RequestExtendVote.t -> Abci.ResponseExtendVote.t B.Io.t

  val verify_vote_extension :
    B.t ->
    Abci.RequestVerifyVoteExtension.t ->
    Abci.ResponseVerifyVoteExtension.t B.Io.t

  val finalize_block :
    B.t -> Abci.RequestFinalizeBlock.t -> Abci.ResponseFinalizeBlock.t B.Io.t

  val commit : B.t -> Abci.RequestCommit.t -> Abci.ResponseCommit.t B.Io.t

  val list_snapshots :
    B.t -> Abci.RequestListSnapshots.t -> Abci.ResponseListSnapshots.t B.Io.t

  val offer_snapshot :
    B.t -> Abci.RequestOfferSnapshot.t -> Abci.ResponseOfferSnapshot.t B.Io.t

  val load_snapshot_chunk :
    B.t ->
    Abci.RequestLoadSnapshotChunk.t ->
    Abci.ResponseLoadSnapshotChunk.t B.Io.t

  val apply_snapshot_chunk :
    B.t ->
    Abci.RequestApplySnapshotChunk.t ->
    Abci.ResponseApplySnapshotChunk.t B.Io.t
end

val code_ok : int
(** [0]. CometBFT's [CodeTypeOK]: a transaction or query succeeded. Any other
    value means failure, and its meaning is the application's to define. *)
