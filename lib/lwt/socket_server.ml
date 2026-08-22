let src = Logs.Src.create "cometbft.socket" ~doc:"ABCI socket transport"

module Log = (val Logs.src_log src : Logs.LOG)

module Make
    (Flow : Mirage_flow.S)
    (A : Cometbft.App.S with type 'a Io.t = 'a Lwt.t) =
struct
  module Dispatch = Cometbft.Dispatch.Make (A)
  module Abci = Cometbft_proto.Types.Tendermint.Abci

  let ( let* ) = Lwt.bind

  let write_response flow response =
    let payload =
      Abci.Response.to_proto response |> Cometbft.Runtime.Writer.contents
    in
    let frame = Cometbft.Framing.encode (Cstruct.of_string payload) in
    let* result = Flow.write flow frame in
    match result with
    | Ok () -> Lwt.return_true
    | Error e ->
        Log.err (fun m -> m "write failed: %a" Flow.pp_write_error e);
        Lwt.return_false

  (* One request at a time, in arrival order. See the .mli: this sequencing is
     the whole reason the node does not kill itself. *)
  let rec drain app flow decoder =
    match Cometbft.Framing.next decoder with
    | `Need_more -> Lwt.return_true
    | `Error e ->
        (* Framing is lost; there is no way to resynchronise a
           length-delimited stream, so the connection is finished. *)
        Log.err (fun m -> m "framing error: %s" e);
        Lwt.return_false
    | `Message payload -> (
        let reader =
          Cometbft.Runtime.Reader.create (Cstruct.to_string payload)
        in
        match Abci.Request.from_proto reader with
        | Error e ->
            (* The frame was well-formed but its contents were not a Request.
               Report it in-band; CometBFT treats that as fatal, which is
               correct -- we cannot know what it asked for. *)
            let msg =
              Format.asprintf "could not decode Request: %a"
                Cometbft.Runtime.Result.pp_error e
            in
            Log.err (fun m -> m "%s" msg);
            let* _ =
              write_response flow (Cometbft.Dispatch.exception_response msg)
            in
            Lwt.return_false
        | Ok request ->
            let* response = Dispatch.handle app request in
            let* ok = write_response flow response in
            if ok then drain app flow decoder else Lwt.return_false)

  let serve app flow =
    let decoder = Cometbft.Framing.create () in
    let rec loop () =
      let* read = Flow.read flow in
      match read with
      | Ok `Eof ->
          Log.debug (fun m -> m "peer closed the connection");
          Lwt.return_unit
      | Error e ->
          Log.err (fun m -> m "read failed: %a" Flow.pp_error e);
          Lwt.return_unit
      | Ok (`Data chunk) ->
          (* Framing takes ownership of [chunk]; Flow.read hands back a fresh
             buffer each time, so there is nothing to copy. *)
          Cometbft.Framing.feed decoder chunk;
          let* continue = drain app flow decoder in
          if continue then loop () else Lwt.return_unit
    in
    let* () = loop () in
    Flow.close flow
end
