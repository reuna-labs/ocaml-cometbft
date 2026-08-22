let src = Logs.Src.create "cometbft.grpc" ~doc:"ABCI gRPC transport"

module Log = (val Logs.src_log src : Logs.LOG)
module Abci = Cometbft_proto.Types.Tendermint.Abci

let service_name = "tendermint.abci.ABCI"

module Make (A : Cometbft.App.S with type 'a Io.t = 'a Lwt.t) = struct
  module Dispatch = Cometbft.Dispatch.Make (A)

  let ( let* ) = Lwt.bind
  let reader s = Cometbft.Runtime.Reader.create s
  let to_string writer = Cometbft.Runtime.Writer.contents writer

  (* Every method has the same shape: decode the method-specific request, put
     it in the envelope, run the shared dispatcher, then pull the
     correspondingly-typed response back out.

     Going through the envelope rather than calling A.<method> directly is
     deliberate. It means the gRPC and socket transports cannot drift apart,
     and that Echo and Flush are answered by the library on both. *)
  let unary ~name ~decode ~encode ~wrap ~unwrap app =
    Grpc_lwt.Server.Rpc.Unary
      (fun body ->
        match decode (reader body) with
        | Error e ->
            let message =
              Format.asprintf "%s: malformed request: %a" name
                Cometbft.Runtime.Result.pp_error e
            in
            Log.err (fun m -> m "%s" message);
            Lwt.return
              (Grpc.Status.v ~message Grpc.Status.Invalid_argument, None)
        | Ok request -> (
            let* response = Dispatch.handle app (wrap request) in
            match unwrap response with
            | Some value ->
                Lwt.return (Grpc.Status.v Grpc.Status.OK, Some (encode value))
            | None ->
                (* Dispatch produced an Exception (a handler raised), or -- which
                   would be a bug here -- a response of the wrong kind. Neither
                   can be expressed as a typed gRPC reply, so it becomes a
                   status. *)
                let message =
                  match response with
                  | `Exception error -> Printf.sprintf "%s: %s" name error
                  | _ ->
                      Printf.sprintf "%s: internal response type mismatch" name
                in
                Log.err (fun m -> m "%s" message);
                Lwt.return (Grpc.Status.v ~message Grpc.Status.Internal, None)))

  let rpcs app =
    let m name ~decode ~encode ~wrap ~unwrap =
      (name, unary ~name ~decode ~encode ~wrap ~unwrap app)
    in
    [
      m "Echo" ~decode:Abci.RequestEcho.from_proto
        ~encode:(fun v -> to_string (Abci.ResponseEcho.to_proto v))
        ~wrap:(fun r -> `Echo r)
        ~unwrap:(function `Echo v -> Some v | _ -> None);
      m "Flush" ~decode:Abci.RequestFlush.from_proto
        ~encode:(fun v -> to_string (Abci.ResponseFlush.to_proto v))
        ~wrap:(fun r -> `Flush r)
        ~unwrap:(function `Flush v -> Some v | _ -> None);
      m "Info" ~decode:Abci.RequestInfo.from_proto
        ~encode:(fun v -> to_string (Abci.ResponseInfo.to_proto v))
        ~wrap:(fun r -> `Info r)
        ~unwrap:(function `Info v -> Some v | _ -> None);
      m "CheckTx" ~decode:Abci.RequestCheckTx.from_proto
        ~encode:(fun v -> to_string (Abci.ResponseCheckTx.to_proto v))
        ~wrap:(fun r -> `Check_tx r)
        ~unwrap:(function `Check_tx v -> Some v | _ -> None);
      m "InsertTx" ~decode:Abci.RequestInsertTx.from_proto
        ~encode:(fun v -> to_string (Abci.ResponseInsertTx.to_proto v))
        ~wrap:(fun r -> `Insert_tx r)
        ~unwrap:(function `Insert_tx v -> Some v | _ -> None);
      m "ReapTxs" ~decode:Abci.RequestReapTxs.from_proto
        ~encode:(fun v -> to_string (Abci.ResponseReapTxs.to_proto v))
        ~wrap:(fun r -> `Reap_txs r)
        ~unwrap:(function `Reap_txs v -> Some v | _ -> None);
      m "Query" ~decode:Abci.RequestQuery.from_proto
        ~encode:(fun v -> to_string (Abci.ResponseQuery.to_proto v))
        ~wrap:(fun r -> `Query r)
        ~unwrap:(function `Query v -> Some v | _ -> None);
      m "Commit" ~decode:Abci.RequestCommit.from_proto
        ~encode:(fun v -> to_string (Abci.ResponseCommit.to_proto v))
        ~wrap:(fun r -> `Commit r)
        ~unwrap:(function `Commit v -> Some v | _ -> None);
      m "InitChain" ~decode:Abci.RequestInitChain.from_proto
        ~encode:(fun v -> to_string (Abci.ResponseInitChain.to_proto v))
        ~wrap:(fun r -> `Init_chain r)
        ~unwrap:(function `Init_chain v -> Some v | _ -> None);
      m "ListSnapshots" ~decode:Abci.RequestListSnapshots.from_proto
        ~encode:(fun v -> to_string (Abci.ResponseListSnapshots.to_proto v))
        ~wrap:(fun r -> `List_snapshots r)
        ~unwrap:(function `List_snapshots v -> Some v | _ -> None);
      m "OfferSnapshot" ~decode:Abci.RequestOfferSnapshot.from_proto
        ~encode:(fun v -> to_string (Abci.ResponseOfferSnapshot.to_proto v))
        ~wrap:(fun r -> `Offer_snapshot r)
        ~unwrap:(function `Offer_snapshot v -> Some v | _ -> None);
      m "LoadSnapshotChunk" ~decode:Abci.RequestLoadSnapshotChunk.from_proto
        ~encode:(fun v -> to_string (Abci.ResponseLoadSnapshotChunk.to_proto v))
        ~wrap:(fun r -> `Load_snapshot_chunk r)
        ~unwrap:(function `Load_snapshot_chunk v -> Some v | _ -> None);
      m "ApplySnapshotChunk" ~decode:Abci.RequestApplySnapshotChunk.from_proto
        ~encode:(fun v ->
          to_string (Abci.ResponseApplySnapshotChunk.to_proto v))
        ~wrap:(fun r -> `Apply_snapshot_chunk r)
        ~unwrap:(function `Apply_snapshot_chunk v -> Some v | _ -> None);
      m "PrepareProposal" ~decode:Abci.RequestPrepareProposal.from_proto
        ~encode:(fun v -> to_string (Abci.ResponsePrepareProposal.to_proto v))
        ~wrap:(fun r -> `Prepare_proposal r)
        ~unwrap:(function `Prepare_proposal v -> Some v | _ -> None);
      m "ProcessProposal" ~decode:Abci.RequestProcessProposal.from_proto
        ~encode:(fun v -> to_string (Abci.ResponseProcessProposal.to_proto v))
        ~wrap:(fun r -> `Process_proposal r)
        ~unwrap:(function `Process_proposal v -> Some v | _ -> None);
      m "ExtendVote" ~decode:Abci.RequestExtendVote.from_proto
        ~encode:(fun v -> to_string (Abci.ResponseExtendVote.to_proto v))
        ~wrap:(fun r -> `Extend_vote r)
        ~unwrap:(function `Extend_vote v -> Some v | _ -> None);
      m "VerifyVoteExtension" ~decode:Abci.RequestVerifyVoteExtension.from_proto
        ~encode:(fun v ->
          to_string (Abci.ResponseVerifyVoteExtension.to_proto v))
        ~wrap:(fun r -> `Verify_vote_extension r)
        ~unwrap:(function `Verify_vote_extension v -> Some v | _ -> None);
      m "FinalizeBlock" ~decode:Abci.RequestFinalizeBlock.from_proto
        ~encode:(fun v -> to_string (Abci.ResponseFinalizeBlock.to_proto v))
        ~wrap:(fun r -> `Finalize_block r)
        ~unwrap:(function `Finalize_block v -> Some v | _ -> None);
    ]

  let service app =
    List.fold_left
      (fun acc (name, rpc) -> Grpc_lwt.Server.Service.add_rpc ~name ~rpc acc)
      (Grpc_lwt.Server.Service.v ())
      (rpcs app)

  let server app =
    Grpc_lwt.Server.v ()
    |> Grpc_lwt.Server.add_service ~name:service_name
         ~service:(Grpc_lwt.Server.Service.handle_request (service app))

  let handler app =
    let server = server app in
    fun reqd -> Grpc_lwt.Server.handle_request server reqd
end
