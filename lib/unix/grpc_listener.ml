let src = Logs.Src.create "cometbft.grpc.unix" ~doc:"ABCI gRPC server on Unix"

module Log = (val Logs.src_log src : Logs.LOG)

module Make (A : Cometbft.App.S with type 'a Io.t = 'a Lwt.t) = struct
  module Grpc_server = Cometbft_grpc.Grpc_server.Make (A)

  let ( let* ) = Lwt.bind

  let listen ?(backlog = 8) app address =
    match address with
    | Server.Unix_socket _ ->
        Lwt.fail_with "gRPC transport requires a tcp:// address"
    | Server.Tcp (host, port) ->
        let inet =
          match Unix.inet_addr_of_string host with
          | addr -> addr
          | exception Failure _ ->
              (Unix.gethostbyname host).Unix.h_addr_list.(0)
        in
        let sockaddr = Unix.ADDR_INET (inet, port) in
        let handler = Grpc_server.handler app in
        let error_handler _client ?request:_ _error start_response =
          (* An HTTP/2-level failure, distinct from an ABCI-level one: the
             latter is already a gRPC status by the time it gets here. *)
          let body = start_response H2.Headers.empty in
          H2.Body.Writer.write_string body "internal error";
          H2.Body.Writer.close body
        in
        let connection_handler =
          H2_lwt_unix.Server.create_connection_handler ?config:None
            ~request_handler:(fun _client reqd -> handler reqd)
            ~error_handler
        in
        let* _server =
          Lwt_io.establish_server_with_client_socket ~backlog sockaddr
            connection_handler
        in
        Log.info (fun m ->
            m "ABCI gRPC server listening on %a" Server.pp_address address);
        (* establish_server_with_client_socket returns once bound; keep the
           process alive the same way the socket listener does. *)
        fst (Lwt.wait ())
end
