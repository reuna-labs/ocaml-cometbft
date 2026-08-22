[@@@ocaml.ppx.context
{
  tool_name = "ppx_driver";
  include_dirs = [];
  hidden_include_dirs = [];
  load_path = ([], []);
  open_modules = [];
  for_package = None;
  debug = false;
  use_threads = false;
  use_vmthreads = false;
  recursive_types = false;
  principal = false;
  transparent_modules = false;
  unboxed_types = false;
  unsafe_string = false;
  cookies =
    [ ("inline_tests", "disabled"); ("library-name", "ocaml_protoc_plugin") ];
}]

module Int64 = struct
  open Int64

  let \#land = logand
  let \#lsl = shift_left
  let \#lsr = shift_right_logical
  let \#lor = logor
  let \#lxor = logxor
  let ( + ) = add
  let ( / ) = div
  let ( * ) = mul
  let ( - ) = sub
  let succ = succ
  let pred = pred
end

module Int = struct
  open Int

  let \#land = logand
  let \#lsl = shift_left
  let \#lsr = shift_right_logical
  let \#lor = logor
  let \#lxor = logxor
  let ( + ) = add
  let ( / ) = div
  let ( * ) = mul
  let ( - ) = sub
  let succ = succ
  let pred = pred
end
