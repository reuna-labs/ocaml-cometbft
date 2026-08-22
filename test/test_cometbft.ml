let cs_of_bytes l =
  Cstruct.of_string
    (String.init (List.length l) (fun i -> Char.chr (List.nth l i)))

(* ------------------------------------------------------------------ varint *)

let check_roundtrip n () =
  let buf = Cstruct.create Cometbft.Varint.max_encoded_length in
  let written = Cometbft.Varint.encode buf n in
  Alcotest.(check int)
    (Printf.sprintf "%d: encoded_length agrees with encode" n)
    (Cometbft.Varint.encoded_length n)
    written;
  match Cometbft.Varint.decode (Cstruct.sub buf 0 written) with
  | `Ok { Cometbft.Varint.value; consumed } ->
      Alcotest.(check int) (Printf.sprintf "%d: value" n) n value;
      Alcotest.(check int) (Printf.sprintf "%d: consumed" n) written consumed
  | `Need_more -> Alcotest.fail "decode wanted more of a complete varint"
  | `Overflow -> Alcotest.fail "decode overflowed on a value we encoded"

(* The boundaries where the encoding grows a byte, plus the frame-size limit
   CometBFT itself enforces. *)
let varint_values =
  [
    0;
    1;
    127;
    128;
    129;
    255;
    256;
    16383;
    16384;
    2097151;
    2097152;
    268435455;
    268435456;
    Int32.to_int Int32.max_int;
  ]

let test_varint_widths () =
  List.iter2
    (fun n expected ->
      Alcotest.(check int)
        (Printf.sprintf "encoded_length %d" n)
        expected
        (Cometbft.Varint.encoded_length n))
    [ 0; 127; 128; 16383; 16384; 2097151; 2097152; 268435455; 268435456 ]
    [ 1; 1; 2; 2; 3; 3; 4; 4; 5 ]

let test_varint_partial () =
  (* 300 = 0xAC 0x02. One byte alone is a continuation, so the decoder must ask
     for more rather than guessing. *)
  let buf = Cstruct.create 2 in
  let _ = Cometbft.Varint.encode buf 300 in
  (match Cometbft.Varint.decode (Cstruct.sub buf 0 1) with
  | `Need_more -> ()
  | _ -> Alcotest.fail "expected Need_more on a truncated varint");
  match Cometbft.Varint.decode (Cstruct.sub buf 0 2) with
  | `Ok { Cometbft.Varint.value; _ } -> Alcotest.(check int) "300" 300 value
  | _ -> Alcotest.fail "expected Ok on the complete varint"

let test_varint_empty () =
  match Cometbft.Varint.decode Cstruct.empty with
  | `Need_more -> ()
  | _ -> Alcotest.fail "expected Need_more on empty input"

let test_varint_overflow () =
  (* Eleven continuation bytes cannot encode anything representable, and must
     be rejected rather than silently wrapping. *)
  let buf =
    cs_of_bytes
      [ 0xff; 0xff; 0xff; 0xff; 0xff; 0xff; 0xff; 0xff; 0xff; 0xff; 0xff ]
  in
  match Cometbft.Varint.decode buf with
  | `Overflow -> ()
  | _ -> Alcotest.fail "expected Overflow"

let test_varint_negative () =
  Alcotest.check_raises "encode rejects negative"
    (Invalid_argument "Varint.encode: negative length") (fun () ->
      ignore (Cometbft.Varint.encode (Cstruct.create 10) (-1)))

(* ----------------------------------------------------------------- framing *)

let test_framing_roundtrip () =
  let payload = Cstruct.of_string "hello abci" in
  let framed = Cometbft.Framing.encode payload in
  let t = Cometbft.Framing.create () in
  Cometbft.Framing.feed t framed;
  match Cometbft.Framing.next t with
  | `Message m ->
      Alcotest.(check string) "payload" "hello abci" (Cstruct.to_string m);
      Alcotest.(check int) "fully consumed" 0 (Cometbft.Framing.pending t)
  | _ -> Alcotest.fail "expected a complete message"

let test_framing_multiple_in_one_read () =
  (* CometBFT pipelines requests, so a single read routinely contains several
     frames; the decoder has to drain them all. *)
  let t = Cometbft.Framing.create () in
  let a = Cometbft.Framing.encode (Cstruct.of_string "one") in
  let b = Cometbft.Framing.encode (Cstruct.of_string "two") in
  let c = Cometbft.Framing.encode (Cstruct.of_string "three") in
  Cometbft.Framing.feed t (Cstruct.concat [ a; b; c ]);
  let got =
    List.filter_map
      (fun () ->
        match Cometbft.Framing.next t with
        | `Message m -> Some (Cstruct.to_string m)
        | _ -> None)
      [ (); (); () ]
  in
  Alcotest.(check (list string)) "all three" [ "one"; "two"; "three" ] got;
  match Cometbft.Framing.next t with
  | `Need_more -> ()
  | _ -> Alcotest.fail "expected Need_more once drained"

let test_framing_split_every_byte () =
  (* The adversarial case: one byte per read, so every frame straddles reads. *)
  let payload = String.init 500 (fun i -> Char.chr (i mod 256)) in
  let framed = Cometbft.Framing.encode (Cstruct.of_string payload) in
  let t = Cometbft.Framing.create () in
  let total = Cstruct.length framed in
  let result = ref None in
  for i = 0 to total - 1 do
    (* Copy each byte, since feed takes ownership of what it is given. *)
    Cometbft.Framing.feed t
      (Cstruct.of_string (String.make 1 (Cstruct.get_char framed i)));
    match Cometbft.Framing.next t with
    | `Message m ->
        if i <> total - 1 then Alcotest.fail "message completed too early";
        result := Some (Cstruct.to_string m)
    | `Need_more -> ()
    | `Error e -> Alcotest.fail e
  done;
  Alcotest.(check (option string)) "reassembled" (Some payload) !result

let test_framing_empty_payload () =
  (* RequestFlush and RequestCommit marshal to zero bytes, so a zero-length
     frame is normal traffic, not an error. *)
  let framed = Cometbft.Framing.encode Cstruct.empty in
  Alcotest.(check int) "just the prefix" 1 (Cstruct.length framed);
  let t = Cometbft.Framing.create () in
  Cometbft.Framing.feed t framed;
  match Cometbft.Framing.next t with
  | `Message m -> Alcotest.(check int) "empty payload" 0 (Cstruct.length m)
  | _ -> Alcotest.fail "expected an empty message"

let test_framing_oversized () =
  let t = Cometbft.Framing.create () in
  (* A varint for 2^31, one past maxMsgSize. *)
  let buf = Cstruct.create 10 in
  let n = Cometbft.Varint.encode buf (Int32.to_int Int32.max_int + 1) in
  Cometbft.Framing.feed t (Cstruct.sub buf 0 n);
  match Cometbft.Framing.next t with
  | `Error _ -> ()
  | _ -> Alcotest.fail "expected an error on an oversized frame"

(* ------------------------------------------------------------------ golden *)

(* These vectors come out of CometBFT's own Go encoder (see golden/README.md),
   so they check the codec against the real implementation rather than against
   our own round-trip. A round-trip test cannot catch a consistently wrong
   framing scheme; this can. *)

module Abci = Cometbft_proto.Types.Tendermint.Abci

let unhex s =
  let n = String.length s / 2 in
  Cstruct.of_string
    (String.init n (fun i ->
         Char.chr (int_of_string ("0x" ^ String.sub s (2 * i) 2))))

let golden_lines () =
  let ic = open_in "golden/abci.golden" in
  let rec go acc =
    match input_line ic with
    | line -> go (line :: acc)
    | exception End_of_file ->
        close_in ic;
        List.rev acc
  in
  go []

let split_fields line = String.split_on_char ' ' line

let test_golden_varints () =
  let cases =
    List.filter_map
      (fun line ->
        match split_fields line with
        | [ "varint"; n; hex ] -> Some (int_of_string n, hex)
        | _ -> None)
      (golden_lines ())
  in
  Alcotest.(check bool) "golden file had varint vectors" true (cases <> []);
  List.iter
    (fun (n, expected_hex) ->
      let buf = Cstruct.create Cometbft.Varint.max_encoded_length in
      let written = Cometbft.Varint.encode buf n in
      let got = Cstruct.to_hex_string (Cstruct.sub buf 0 written) in
      Alcotest.(check string)
        (Printf.sprintf "uvarint %d matches Go" n)
        expected_hex got)
    cases

let golden_frames () =
  List.filter_map
    (fun line ->
      match split_fields line with
      | [ "frame"; label; hex ] -> Some (label, hex)
      | _ -> None)
    (golden_lines ())

(* Decode a golden frame all the way to a Request, exercising framing and
   protobuf together. *)
let decode_frame hex =
  let t = Cometbft.Framing.create () in
  Cometbft.Framing.feed t (unhex hex);
  match Cometbft.Framing.next t with
  | `Message payload -> (
      Alcotest.(check int) "frame fully consumed" 0 (Cometbft.Framing.pending t);
      let reader = Cometbft.Runtime.Reader.create (Cstruct.to_string payload) in
      match Abci.Request.from_proto reader with
      | Ok req -> req
      | Error _ -> Alcotest.fail "protobuf decode failed on a Go-produced frame"
      )
  | `Need_more -> Alcotest.fail "framing wanted more of a complete Go frame"
  | `Error e -> Alcotest.fail e

let frame_named label =
  match List.assoc_opt label (golden_frames ()) with
  | Some hex -> hex
  | None -> Alcotest.fail (Printf.sprintf "golden file has no frame %S" label)

let test_golden_echo () =
  match decode_frame (frame_named "echo") with
  (* Single-field messages are unwrapped by the plugin: RequestEcho.t is a
     bare string, not a record. *)
  | `Echo message -> Alcotest.(check string) "message" "hello abci" message
  | _ -> Alcotest.fail "expected Echo"

let test_golden_flush () =
  match decode_frame (frame_named "flush") with
  | `Flush _ -> ()
  | _ -> Alcotest.fail "expected Flush"

let test_golden_info () =
  match decode_frame (frame_named "info") with
  | `Info r ->
      let open Abci.RequestInfo in
      Alcotest.(check string) "version" "1.2.3" r.version;
      Alcotest.(check string) "abci_version" "2.0.0" r.abci_version;
      Alcotest.(check int64) "block_version" 11L r.block_version;
      Alcotest.(check int64) "p2p_version" 8L r.p2p_version
  | _ -> Alcotest.fail "expected Info"

let test_golden_check_tx () =
  match decode_frame (frame_named "check_tx") with
  | `Check_tx r ->
      let open Abci.RequestCheckTx in
      Alcotest.(check string) "tx" "key=value" (Bytes.to_string r.tx);
      (* Field 2 with RECHECK = 1. Getting this wrong is exactly the failure
         that targeting the cometbft.abci.v1 protos would have produced, since
         there the field moved to 3 under a renumbered enum. *)
      Alcotest.(check bool)
        "type is Recheck" true
        (r.type' = Abci.CheckTxType.RECHECK)
  | _ -> Alcotest.fail "expected Check_tx"

let test_golden_commit () =
  match decode_frame (frame_named "commit") with
  | `Commit _ -> ()
  | _ -> Alcotest.fail "expected Commit"

let test_golden_finalize_block () =
  match decode_frame (frame_named "finalize_block") with
  | `Finalize_block r ->
      let open Abci.RequestFinalizeBlock in
      Alcotest.(check (list string))
        "txs" [ "tx1"; "tx2" ]
        (List.map Bytes.to_string r.txs);
      Alcotest.(check int64) "height" 42L r.height;
      Alcotest.(check string) "hash" "blockhash" (Bytes.to_string r.hash)
  | _ -> Alcotest.fail "expected Finalize_block"

(* Re-encoding a Go frame must reproduce it byte for byte, which is the
   strongest single statement we can make about wire compatibility. *)
let test_golden_reencode () =
  List.iter
    (fun (label, hex) ->
      let req = decode_frame hex in
      let payload =
        Abci.Request.to_proto req |> Cometbft.Runtime.Writer.contents
      in
      let reframed = Cometbft.Framing.encode (Cstruct.of_string payload) in
      Alcotest.(check string)
        (Printf.sprintf "%s re-encodes byte-identically" label)
        hex
        (Cstruct.to_hex_string reframed))
    (golden_frames ())

(* ---------------------------------------------------------------- dispatch *)

(* An application that overrides nothing: every handler is the default. *)
module Passthrough = struct
  type t = unit

  module Io = Cometbft.App.Identity

  include Cometbft.App.Defaults (struct
    type nonrec t = t

    module Io = Io
  end)
end

module D = Cometbft.Dispatch.Make (Passthrough)

let request_label : Abci.Request.t -> string = function
  | `Echo _ -> "echo"
  | `Flush _ -> "flush"
  | `Info _ -> "info"
  | `Init_chain _ -> "init_chain"
  | `Query _ -> "query"
  | `Check_tx _ -> "check_tx"
  | `Commit _ -> "commit"
  | `List_snapshots _ -> "list_snapshots"
  | `Offer_snapshot _ -> "offer_snapshot"
  | `Load_snapshot_chunk _ -> "load_snapshot_chunk"
  | `Apply_snapshot_chunk _ -> "apply_snapshot_chunk"
  | `Prepare_proposal _ -> "prepare_proposal"
  | `Process_proposal _ -> "process_proposal"
  | `Extend_vote _ -> "extend_vote"
  | `Verify_vote_extension _ -> "verify_vote_extension"
  | `Finalize_block _ -> "finalize_block"
  | `Insert_tx _ -> "insert_tx"
  | `Reap_txs _ -> "reap_txs"
  | `not_set -> "not_set"

let response_label : Abci.Response.t -> string = function
  | `Exception _ -> "exception"
  | `Echo _ -> "echo"
  | `Flush _ -> "flush"
  | `Info _ -> "info"
  | `Init_chain _ -> "init_chain"
  | `Query _ -> "query"
  | `Check_tx _ -> "check_tx"
  | `Commit _ -> "commit"
  | `List_snapshots _ -> "list_snapshots"
  | `Offer_snapshot _ -> "offer_snapshot"
  | `Load_snapshot_chunk _ -> "load_snapshot_chunk"
  | `Apply_snapshot_chunk _ -> "apply_snapshot_chunk"
  | `Prepare_proposal _ -> "prepare_proposal"
  | `Process_proposal _ -> "process_proposal"
  | `Extend_vote _ -> "extend_vote"
  | `Verify_vote_extension _ -> "verify_vote_extension"
  | `Finalize_block _ -> "finalize_block"
  | `Insert_tx _ -> "insert_tx"
  | `Reap_txs _ -> "reap_txs"
  | `not_set -> "not_set"

(* One request of every kind the protocol defines. *)
let all_requests : Abci.Request.t list =
  [
    `Echo "hi";
    `Flush ();
    `Info (Abci.RequestInfo.make ());
    `Init_chain (Abci.RequestInitChain.make ());
    `Query (Abci.RequestQuery.make ());
    `Check_tx (Abci.RequestCheckTx.make ());
    `Commit (Abci.RequestCommit.make ());
    `List_snapshots (Abci.RequestListSnapshots.make ());
    `Offer_snapshot (Abci.RequestOfferSnapshot.make ());
    `Load_snapshot_chunk (Abci.RequestLoadSnapshotChunk.make ());
    `Apply_snapshot_chunk (Abci.RequestApplySnapshotChunk.make ());
    `Prepare_proposal (Abci.RequestPrepareProposal.make ());
    `Process_proposal (Abci.RequestProcessProposal.make ());
    `Extend_vote (Abci.RequestExtendVote.make ());
    `Verify_vote_extension (Abci.RequestVerifyVoteExtension.make ());
    `Finalize_block (Abci.RequestFinalizeBlock.make ());
    `Insert_tx (Abci.RequestInsertTx.make ());
    `Reap_txs (Abci.RequestReapTxs.make ());
  ]

(* Every request must come back as a response of the same kind. CometBFT pops
   the oldest outstanding request and compares types; a mismatch raises
   ErrUnexpectedResponse and kills the node, so this is a load-bearing test
   rather than a tautology. *)
let test_dispatch_kind_matches () =
  Alcotest.(check int) "covers every request tag" 18 (List.length all_requests);
  List.iter
    (fun req ->
      let expected = request_label req in
      let got = response_label (D.handle () req) in
      Alcotest.(check string)
        (Printf.sprintf "%s round-trips its kind" expected)
        expected got)
    all_requests

let test_dispatch_not_set () =
  Alcotest.(check string)
    "unset oneof becomes an exception" "exception"
    (response_label (D.handle () `not_set))

(* An application that raises on every call. *)
module Exploding = struct
  type t = unit

  module Io = Cometbft.App.Identity

  include Cometbft.App.Defaults (struct
    type nonrec t = t

    module Io = Io
  end)

  let check_tx _ _ = failwith "boom"
end

module DE = Cometbft.Dispatch.Make (Exploding)

let test_dispatch_exception () =
  (* A raising handler must not tear down the connection; it becomes an ABCI
     Exception response so the node learns about it in-band. *)
  match DE.handle () (`Check_tx (Abci.RequestCheckTx.make ())) with
  | `Exception e ->
      Alcotest.(check bool)
        "carries the failure text" true
        (String.length e > 0 && e <> "")
  | other ->
      Alcotest.fail
        ("expected an exception response, got " ^ response_label other)

let test_dispatch_echo_is_local () =
  match D.handle () (`Echo "ping") with
  | `Echo m -> Alcotest.(check string) "echoes verbatim" "ping" m
  | other -> Alcotest.fail (response_label other)

(* ---------------------------------------------------------------- defaults *)

let test_default_process_proposal_accepts () =
  (* The zero value of ProposalStatus is UNKNOWN, which CometBFT treats as an
     error, so defaulting to it would break every chain that used the defaults. *)
  match
    D.handle () (`Process_proposal (Abci.RequestProcessProposal.make ()))
  with
  | `Process_proposal status ->
      Alcotest.(check bool)
        "ACCEPT" true
        (status = Abci.ResponseProcessProposal.ProposalStatus.ACCEPT)
  | other -> Alcotest.fail (response_label other)

let test_default_verify_vote_extension_accepts () =
  match
    D.handle ()
      (`Verify_vote_extension (Abci.RequestVerifyVoteExtension.make ()))
  with
  | `Verify_vote_extension status ->
      Alcotest.(check bool)
        "ACCEPT" true
        (status = Abci.ResponseVerifyVoteExtension.VerifyStatus.ACCEPT)
  | other -> Alcotest.fail (response_label other)

let test_default_finalize_block_result_per_tx () =
  (* CometBFT rejects a FinalizeBlock response whose tx_results length differs
     from the number of transactions in the request. *)
  let txs = List.map Bytes.of_string [ "a"; "b"; "c" ] in
  match
    D.handle () (`Finalize_block (Abci.RequestFinalizeBlock.make ~txs ()))
  with
  | `Finalize_block r ->
      Alcotest.(check int)
        "one result per tx" 3
        (List.length r.Abci.ResponseFinalizeBlock.tx_results)
  | other -> Alcotest.fail (response_label other)

let test_default_prepare_proposal_honours_max_bytes () =
  let txs = List.map Bytes.of_string [ "aaaa"; "bbbb"; "cccc" ] in
  (* Room for two of the three four-byte transactions. *)
  let req = Abci.RequestPrepareProposal.make ~txs ~max_tx_bytes:9L () in
  match D.handle () (`Prepare_proposal req) with
  | `Prepare_proposal kept ->
      Alcotest.(check (list string))
        "truncated at the limit" [ "aaaa"; "bbbb" ]
        (List.map Bytes.to_string kept)
  | other -> Alcotest.fail (response_label other)

let test_default_prepare_proposal_passthrough () =
  let txs = List.map Bytes.of_string [ "one"; "two" ] in
  let req = Abci.RequestPrepareProposal.make ~txs ~max_tx_bytes:1000L () in
  match D.handle () (`Prepare_proposal req) with
  | `Prepare_proposal kept ->
      Alcotest.(check (list string))
        "passes everything through" [ "one"; "two" ]
        (List.map Bytes.to_string kept)
  | other -> Alcotest.fail (response_label other)

let () =
  Alcotest.run "cometbft"
    [
      ( "varint",
        List.map
          (fun n ->
            Alcotest.test_case (string_of_int n) `Quick (check_roundtrip n))
          varint_values
        @ [
            Alcotest.test_case "encoded widths" `Quick test_varint_widths;
            Alcotest.test_case "partial input" `Quick test_varint_partial;
            Alcotest.test_case "empty input" `Quick test_varint_empty;
            Alcotest.test_case "overflow" `Quick test_varint_overflow;
            Alcotest.test_case "negative" `Quick test_varint_negative;
          ] );
      ( "framing",
        [
          Alcotest.test_case "roundtrip" `Quick test_framing_roundtrip;
          Alcotest.test_case "several frames per read" `Quick
            test_framing_multiple_in_one_read;
          Alcotest.test_case "one byte per read" `Quick
            test_framing_split_every_byte;
          Alcotest.test_case "empty payload" `Quick test_framing_empty_payload;
          Alcotest.test_case "oversized frame" `Quick test_framing_oversized;
        ] );
      ( "golden (vs CometBFT's Go encoder)",
        [
          Alcotest.test_case "uvarint vectors" `Quick test_golden_varints;
          Alcotest.test_case "echo" `Quick test_golden_echo;
          Alcotest.test_case "flush" `Quick test_golden_flush;
          Alcotest.test_case "info" `Quick test_golden_info;
          Alcotest.test_case "check_tx" `Quick test_golden_check_tx;
          Alcotest.test_case "commit" `Quick test_golden_commit;
          Alcotest.test_case "finalize_block" `Quick test_golden_finalize_block;
          Alcotest.test_case "re-encode is byte-identical" `Quick
            test_golden_reencode;
        ] );
      ( "dispatch",
        [
          Alcotest.test_case "response kind matches request kind" `Quick
            test_dispatch_kind_matches;
          Alcotest.test_case "unset oneof" `Quick test_dispatch_not_set;
          Alcotest.test_case "handler exception becomes Exception" `Quick
            test_dispatch_exception;
          Alcotest.test_case "echo answered by the library" `Quick
            test_dispatch_echo_is_local;
        ] );
      ( "defaults",
        [
          Alcotest.test_case "process_proposal ACCEPTs" `Quick
            test_default_process_proposal_accepts;
          Alcotest.test_case "verify_vote_extension ACCEPTs" `Quick
            test_default_verify_vote_extension_accepts;
          Alcotest.test_case "finalize_block: one result per tx" `Quick
            test_default_finalize_block_result_per_tx;
          Alcotest.test_case "prepare_proposal honours max_tx_bytes" `Quick
            test_default_prepare_proposal_honours_max_bytes;
          Alcotest.test_case "prepare_proposal passes txs through" `Quick
            test_default_prepare_proposal_passthrough;
        ] );
    ]
