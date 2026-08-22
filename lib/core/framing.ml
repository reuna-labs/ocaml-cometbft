let max_frame_length = Int32.to_int Int32.max_int

let encode payload =
  let len = Cstruct.length payload in
  if len > max_frame_length then
    invalid_arg "Framing.encode: payload exceeds maxMsgSize";
  let prefix_len = Varint.encoded_length len in
  let out = Cstruct.create (prefix_len + len) in
  let written = Varint.encode out len in
  assert (written = prefix_len);
  Cstruct.blit payload 0 out prefix_len len;
  out

(* [buffered] is a view over bytes handed to [feed]. Popping a frame only shifts
   the window, and [next] returns a sub-view, so the common case -- a read that
   yields one or more whole frames -- copies nothing at all. The one copy is in
   [feed], and only when a frame straddles two reads so the leftover has to be
   joined to the next chunk. *)
type t = { mutable buffered : Cstruct.t }

let create () = { buffered = Cstruct.empty }
let pending t = Cstruct.length t.buffered

let feed t chunk =
  if Cstruct.length chunk > 0 then
    t.buffered <-
      (if Cstruct.is_empty t.buffered then chunk
       else Cstruct.append t.buffered chunk)

let next t =
  match Varint.decode t.buffered with
  | `Need_more -> `Need_more
  | `Overflow -> `Error "length prefix overflows a 64-bit integer"
  | `Ok { Varint.value; consumed } ->
      if value > max_frame_length then
        `Error
          (Printf.sprintf "frame length %d exceeds maxMsgSize %d" value
             max_frame_length)
      else if Cstruct.length t.buffered - consumed < value then `Need_more
      else begin
        let payload = Cstruct.sub t.buffered consumed value in
        t.buffered <- Cstruct.shift t.buffered (consumed + value);
        `Message payload
      end
