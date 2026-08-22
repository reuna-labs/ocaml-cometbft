(* Deliberately empty.

   ocaml-protoc-plugin emits [module Gogo = Gogo] into the [Imported'modules]
   block of every generated file, because the CometBFT protos all
   [import "gogoproto/gogo.proto"]. They only ever use its *options*
   -- (gogoproto.nullable), (gogoproto.stdtime), (gogoproto.customname) and
   friends -- which are Go code-generation hints with no effect on the wire
   format, and never any of its message types.

   So the reference has to resolve, but there is nothing for it to resolve to.
   Generating gogo.proto for real would pull in descriptor.proto and a large
   body of extension definitions that no ABCI message touches. An empty
   compilation unit is the whole fix; nethsm's etcd_client does the same thing.

   This file is hand-written and lives outside gen/, which gen.sh wipes. *)
