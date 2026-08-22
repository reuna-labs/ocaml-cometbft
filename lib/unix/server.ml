let src = Logs.Src.create "cometbft.unix" ~doc:"ABCI server on Unix"

module Log = (val Logs.src_log src : Logs.LOG)

type address = Tcp of string * int | Unix_socket of string

let pp_address ppf = function
  | Tcp (host, port) -> Format.fprintf ppf "tcp://%s:%d" host port
  | Unix_socket path -> Format.fprintf ppf "unix://%s" path

let parse_host_port s =
  match String.rindex_opt s ':' with
  | None -> Error (Printf.sprintf "expected host:port, got %S" s)
  | Some i -> (
      let host = String.sub s 0 i in
      let port = String.sub s (i + 1) (String.length s - i - 1) in
      match int_of_string_opt port with
      | Some p when p > 0 && p < 65536 ->
          Ok (Tcp ((if host = "" then "0.0.0.0" else host), p))
      | _ -> Error (Printf.sprintf "invalid port %S" port))

let has_prefix ~prefix s =
  String.length s >= String.length prefix
  && String.sub s 0 (String.length prefix) = prefix

let drop n s = String.sub s n (String.length s - n)

let parse_address s =
  if has_prefix ~prefix:"tcp://" s then parse_host_port (drop 6 s)
  else if has_prefix ~prefix:"unix://" s then
    (* CometBFT writes unix:///tmp/abci.sock, so what follows the scheme is
       already an absolute path; nothing to re-add. *)
    match drop 7 s with
    | "" -> Error "unix:// address has an empty path"
    | path -> Ok (Unix_socket path)
  else if String.contains s ':' then parse_host_port s
  else Error (Printf.sprintf "unrecognised address %S" s)

module Make (A : Cometbft.App.S with type 'a Io.t = 'a Lwt.t) = struct
  module Server = Cometbft_lwt.Socket_server.Make (Mirage_flow_unix.Fd) (A)

  let ( let* ) = Lwt.bind

  let bind_socket ?(backlog = 8) address =
    let domain, sockaddr =
      match address with
      | Tcp (host, port) ->
          let inet =
            match Unix.inet_addr_of_string host with
            | addr -> addr
            | exception Failure _ ->
                (Unix.gethostbyname host).Unix.h_addr_list.(0)
          in
          ( Unix.domain_of_sockaddr (Unix.ADDR_INET (inet, port)),
            Unix.ADDR_INET (inet, port) )
      | Unix_socket path ->
          (* A socket file left behind by a previous run would make bind fail
             with EADDRINUSE even though nothing is listening. *)
          (try Unix.unlink path with Unix.Unix_error _ -> ());
          (Unix.PF_UNIX, Unix.ADDR_UNIX path)
    in
    let fd = Lwt_unix.socket domain Unix.SOCK_STREAM 0 in
    (match address with
    | Tcp _ -> Lwt_unix.setsockopt fd Unix.SO_REUSEADDR true
    | Unix_socket _ -> ());
    let* () = Lwt_unix.bind fd sockaddr in
    Lwt_unix.listen fd backlog;
    Lwt.return fd

  let listen ?backlog app address =
    let* listening = bind_socket ?backlog address in
    Log.info (fun m -> m "ABCI server listening on %a" pp_address address);
    let rec accept_loop () =
      let* client, _peer = Lwt_unix.accept listening in
      (* CometBFT opens four connections and expects all of them to be served,
         so each runs concurrently. A connection ending must not end the
         listener: a node that restarts will reconnect. *)
      Lwt.async (fun () ->
          Lwt.catch
            (fun () -> Server.serve app client)
            (fun exn ->
              Log.err (fun m ->
                  m "connection handler failed: %s" (Printexc.to_string exn));
              Lwt.catch
                (fun () -> Lwt_unix.close client)
                (fun _ -> Lwt.return_unit)));
      accept_loop ()
    in
    accept_loop ()
end
