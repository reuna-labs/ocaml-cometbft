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

  let ( + ) = add
  let ( / ) = div
  let ( * ) = mul
  let ( - ) = sub
  let succ = succ
  let pred = pred
end

module Int = struct
  open Int

  let ( + ) = add
  let ( / ) = div
  let ( * ) = mul
  let ( - ) = sub
  let succ = succ
  let pred = pred
end
