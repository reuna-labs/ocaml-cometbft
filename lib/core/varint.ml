let max_encoded_length = 10

let encoded_length n =
  if n < 0 then invalid_arg "Varint.encoded_length: negative length";
  let rec go n acc = if n < 0x80 then acc + 1 else go (n lsr 7) (acc + 1) in
  go n 0

let encode buf n =
  if n < 0 then invalid_arg "Varint.encode: negative length";
  let needed = encoded_length n in
  if Cstruct.length buf < needed then
    invalid_arg "Varint.encode: buffer too small";
  let rec go i n =
    if n < 0x80 then (
      Cstruct.set_uint8 buf i n;
      i + 1)
    else (
      Cstruct.set_uint8 buf i (n land 0x7f lor 0x80);
      go (i + 1) (n lsr 7))
  in
  go 0 n

type decoded = { value : int; consumed : int }

let decode buf =
  let len = Cstruct.length buf in
  let rec go i acc shift =
    if i >= len then `Need_more
    else if i >= max_encoded_length then `Overflow
    else
      let byte = Cstruct.get_uint8 buf i in
      let payload = byte land 0x7f in
      (* Fold in this group of seven bits, refusing anything that would not fit
         in an OCaml int. Both guards matter: [lsr]/[lsl] by more than the word
         size is undefined, so the [shift >= Sys.int_size] case has to be taken
         before the arithmetic one. A continuation byte carrying only zeroes is
         redundant but harmless, so it is tolerated rather than rejected. *)
      let overflows =
        if shift >= Sys.int_size then payload <> 0
        else payload > max_int lsr shift
      in
      if overflows then `Overflow
      else
        let acc =
          if shift >= Sys.int_size then acc else acc lor (payload lsl shift)
        in
        if byte < 0x80 then `Ok { value = acc; consumed = i + 1 }
        else go (i + 1) acc (shift + 7)
  in
  go 0 0 0
