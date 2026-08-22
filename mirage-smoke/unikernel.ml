(* Instantiate the ABCI stack against a Mirage TCP stack.

   Whether this unikernel does anything useful is beside the point -- it is a
   compile-time assertion that the server functors really are satisfied by a
   Mirage_flow.S coming from Tcpip, with no unix anywhere in the dependency
   cone. *)

module Make (Stack : Tcpip.Stack.V4V6) = struct
  (* An application that overrides nothing: the defaults are a complete,
     spec-compliant ABCI application already. *)
  module App = struct
    type t = unit

    module Io = Cometbft_lwt.Lwt_io_monad

    include Cometbft.App.Defaults (struct
      type nonrec t = t

      module Io = Io
    end)
  end

  (* Stack.TCP is a Mirage_flow.S, which is all Socket_server.Make asks for. *)
  module Server = Cometbft_lwt.Socket_server.Make (Stack.TCP) (App)

  let abci_port = 26658

  let start stack =
    Stack.TCP.listen (Stack.tcp stack) ~port:abci_port (fun flow ->
        Server.serve () flow);
    Stack.listen stack
end
