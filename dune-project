(lang dune 3.0)
(name cometbft)

; Opam files are hand-written (see *.opam in the repo root) rather than
; generated. The gRPC transport needs a pinned git SHA of ocaml-grpc -- see the
; comment in cometbft-lwt.opam -- which dune's generator cannot express.
