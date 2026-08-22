type error =
  [ `Premature_end_of_input
  | `Unknown_field_type of int
  | `Wrong_field_type of string * string
  | `Illegal_value of string * Field.t
  | `Unknown_enum_value of int
  | `Unknown_enum_name of string
  | `Required_field_missing of int * string ]

exception Error of error

type 'a t = ('a, error) result

val raise : error -> 'a
(** Raise [error] as an exception of type Result.Error *)

val catch : (unit -> 'a) -> ('a, [> error ]) result
(** catch [f] catches any exception of type Result.Error raised and returns a
    result type *)

val ( >>| ) : 'a t -> ('a -> 'b) -> 'b t
(** Monadic map *)

val ( >>= ) : 'a t -> ('a -> 'b t) -> 'b t
(** Monadoc bind *)

val return : 'a -> 'a t
(** Monadic return *)

val fail : error -> 'a t
(** Create the error state *)

val get : msg:string -> 'a t -> 'a
(** Get the value or fail with the given message *)

val pp_error : Format.formatter -> error -> unit
(** Pretty printer of the error type *)

val show_error : error -> string
(** Create a string representation of [error] *)

val pp :
  (Format.formatter -> 'a -> unit) ->
  Format.formatter ->
  ('a, [< error ]) result ->
  unit
(** Prettyprinter *)
