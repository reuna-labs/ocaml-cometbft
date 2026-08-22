# Vendored `ocaml_protoc_plugin` runtime

This is the runtime library of [ocaml-protoc-plugin][] 6.2.0, vendored with its
ppx pre-expanded. It is not modified by hand.

## Why vendor it

The generated bindings need this runtime, and the runtime itself is tiny --
`(libraries base64 ptime)`, both fine for a unikernel. The *package*, however,
depends on `ppx_expect`, `ppx_inline_test`, `omd`, `conf-protoc` and
`conf-pkg-config`, because those are what building and testing the code
generator needs.

That cone makes `opam monorepo lock` fail outright: `omd` pulls `uutf`/`uunf`/
`uucp`, `conf-protoc` wants a `protoc` binary at build time, and several have no
Dune port. So a MirageOS/Solo5 unikernel could not vendor its dependencies at
all while `cometbft-proto` depended on the package.

Vendoring the runtime alone cuts the dependency to `base64` + `ptime` and the
unikernel builds. nethsm's `etcd_client` reached the same conclusion
independently; this follows its recipe.

## Regenerating

The ppx is only used for inline tests, so expanding under the *release* profile
removes it entirely -- under `dev` the expansion leaves calls to
`Ppx_inline_test_lib` and `Expect_test_collector` behind, which would put those
libraries back in the dependency cone.

```sh
opam source ocaml-protoc-plugin --dir=/tmp/opp
cd /tmp/opp
mkdir -p pp/src/ocaml_protoc_plugin
for i in src/ocaml_protoc_plugin/*.ml; do
  # dune prints compiler diagnostics on stdout *after* the expanded source, so
  # they have to be cut off or they end up inside the vendored .ml files.
  dune describe pp "$i" --profile release 2>/dev/null \
    | sed '/^File "src\/ocaml_protoc_plugin\//,$d' > "pp/$i"
done
cp src/ocaml_protoc_plugin/*.mli  <repo>/lib/proto/runtime/
cp pp/src/ocaml_protoc_plugin/*.ml <repo>/lib/proto/runtime/
```

Then check nothing crept back in:

```sh
grep -c 'Ppx_inline_test_lib\|Expect_test_collector' lib/proto/runtime/*.ml
grep -l '^File "src/' lib/proto/runtime/*.ml
```

[ocaml-protoc-plugin]: https://github.com/andersfugmann/ocaml-protoc-plugin
