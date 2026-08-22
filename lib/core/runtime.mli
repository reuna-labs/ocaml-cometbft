(** The protobuf runtime, under a stable name.

    [ocaml-protoc-plugin]'s runtime is vendored inside {!Cometbft_proto} rather
    than depended on as an opam package -- see [lib/proto/runtime/README.md] for
    why -- so it is not available as a top-level [Ocaml_protoc_plugin] library.

    Transport code needs it to encode and decode messages, so it is re-exported
    here. Going through this alias means the vendoring is one line to undo if
    upstream ever splits the runtime into its own package. *)

include module type of Cometbft_proto.Ocaml_protoc_plugin
