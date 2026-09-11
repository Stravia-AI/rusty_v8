#!/usr/bin/env bash
set -euxo pipefail

# Only the SDK producer enters this path. All compilers and executable V8
# generators run on a same-architecture Debian 12 glibc host.
case "$TARGET" in
  x86_64-unknown-linux-gnu|aarch64-unknown-linux-gnu|x86_64-unknown-linux-musl|aarch64-unknown-linux-musl) ;;
  *) echo "Unsupported target: $TARGET" >&2; exit 1 ;;
esac
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg git python3 g++ make pkg-config xz-utils unzip binutils
curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key | gpg --dearmor -o /usr/share/keyrings/llvm.gpg
printf '%s\n' 'deb [signed-by=/usr/share/keyrings/llvm.gpg] https://apt.llvm.org/bookworm/ llvm-toolchain-bookworm-23 main' > /etc/apt/sources.list.d/llvm.list
apt-get update
case "$(dpkg --print-architecture)" in
  amd64|arm64) llvm_package_version='1:23.1.2~++20260910044042+069ef0e7cb36-1~exp1~20260910044052.71' ;;
  *) echo 'Unsupported native compiler architecture' >&2; exit 1 ;;
esac
llvm_packages=(clang-23 lld-23 llvm-23 libclang-23-dev libclang-rt-23-dev)
llvm_inputs=()
for package in "${llvm_packages[@]}"; do llvm_inputs+=("$package=$llvm_package_version"); done
# apt checks the downloaded package hashes against its authenticated index.
# Retain the exact package versions, source URLs and SHA256 identities.
apt-cache show "${llvm_inputs[@]}" > compiler-packages.txt
python3 - "$(dpkg --print-architecture)" <<'PY'
import pathlib, sys
packages = ('clang-23', 'lld-23', 'llvm-23', 'libclang-23-dev', 'libclang-rt-23-dev')
hashes = {
    'amd64': (
        '37b18b59ae24b157cbb7ab6e75d3e9bee869e0e1b09f7d5cdc52fcff8a8c7a0d',
        'b211b579c71d54beb0acb985477da256b8bda36cb6245ff1e5fe98fb6f9300fe',
        'fd6e846d652417f7010c4c4bfa62814f5cf8165ffbd1e2d2650b4e19e4706e57',
        '3dbf60a9aec6bdf8cbaa4750e9d8d4d9a2ef26dd532a0df6c9bc26413c335392',
        '3043f1ccdadcb8d533f878ffe3add7b2ae68d150bf0c5b5f21d706d3472608e4',
    ),
    'arm64': (
        '51ea86c1ee833ff8df683f8fe19aeecc99b3a7a778c55b5185a1a2facc9edde0',
        '8f1e5d02d8811399340f5e6d5ef091247e41d6a77d4684ee61ba94fefbc1e1ae',
        '80713fd373370646ea471fdf01315ee14c68927f44283870a2ba3dfaf02919ab',
        'd3d1220ecb44d465466d3a598181d54ed55c74501549010280f7372531725c99',
        '5485aa70c55a6b51d0e0df049ba1b1d4d6e651f5e01e5d93edd082cf71514195',
    ),
}
expected = dict(zip(packages, hashes[sys.argv[1]]))
seen = set()
for block in pathlib.Path('compiler-packages.txt').read_text().strip().split('\n\n'):
    fields = dict(line.split(': ', 1) for line in block.splitlines() if ': ' in line and not line.startswith(' '))
    name = fields['Package']
    assert fields['SHA256'] == expected[name], (name, fields['SHA256'])
    seen.add(name)
assert seen == set(expected), seen
PY
apt-get install -y --no-install-recommends "${llvm_inputs[@]}"
curl -fsSL https://sh.rustup.rs -o /tmp/rustup.sh
sh /tmp/rustup.sh -y --profile minimal --default-host "${TARGET%-*}-gnu" --default-toolchain none
export PATH="/root/.cargo/bin:/usr/lib/llvm-23/bin:$PATH"
export LIBCLANG_PATH=/usr/lib/llvm-23/lib
export RUSTY_V8_BINDGEN_RESOURCE_DIR=$(/usr/lib/llvm-23/bin/clang -print-resource-dir)
# Native distro compilers, never Chromium's x64-only Linux executables.
# GN accepts the actual Clang major version. Its runtime config expects a
# per-triple archive name; stage the genuine archives without changing bytes.
export CLANG_BASE_PATH=/work/target/moli-clang
mkdir -p "$CLANG_BASE_PATH"
ln -s /usr/lib/llvm-23/bin "$CLANG_BASE_PATH/bin"
compiler_arch=${TARGET%%-*}
compiler_host="$compiler_arch-unknown-linux-gnu"
case "$(clang -dumpmachine)" in
  "$compiler_arch"-*-linux-gnu) ;;
  *) echo 'Clang host triple does not match the native SDK target' >&2; exit 1 ;;
esac
resource_dir=$(clang -print-resource-dir)
test "${resource_dir##*/}" = 23
runtime_dir="$CLANG_BASE_PATH/lib/clang/23/lib/$compiler_host"
mkdir -p "$runtime_dir"
ln -s "$resource_dir/include" "$CLANG_BASE_PATH/lib/clang/23/include"
for runtime_name in builtins profile; do
  source_runtime="$resource_dir/lib/linux/libclang_rt.$runtime_name-$compiler_arch.a"
  staged_runtime="$runtime_dir/libclang_rt.$runtime_name.a"
  test -f "$source_runtime"
  cp "$source_runtime" "$staged_runtime"
  cmp "$source_runtime" "$staged_runtime"
  sha256sum "$source_runtime" "$staged_runtime" >> compiler-runtime.sha256
  readelf -h "$staged_runtime" >> compiler-runtime-headers.txt
done
python3 - "$compiler_arch" <<'PY'
import pathlib, sys
machines = {line.split(':', 1)[1].strip() for line in pathlib.Path('compiler-runtime-headers.txt').read_text().splitlines() if 'Machine:' in line}
expected = {'x86_64': 'Advanced Micro Devices X86-64', 'aarch64': 'AArch64'}[sys.argv[1]]
assert machines == {expected}, (machines, expected)
PY
mkdir -p compiler-notices
for package in "${llvm_packages[@]}"; do
  cp "/usr/share/doc/$package/copyright" "compiler-notices/$package.copyright"
done
export PATH="$CLANG_BASE_PATH/bin:$PATH"
export RUSTUP_TOOLCHAIN=1.91.0
export CARGO_BUILD_JOBS=2
git config --global --add safe.directory /work
rustup toolchain install "$RUSTUP_TOOLCHAIN" --profile minimal --no-self-update
rustup target add "$TARGET"

# GN's bindgen action needs its CLI, formatter and libclang independently
# of rustc/std. Build these host tools before applying the musl target flags.
host_tools=/work/target/moli-host-tools
cargo install bindgen-cli --version 0.72.1 --locked --target "$compiler_host" --root "$host_tools"
ln -s /work/third_party/rust-toolchain/bin/rustfmt "$host_tools/bin/rustfmt"
ln -s /usr/lib/llvm-23/lib "$host_tools/lib"
"$host_tools/bin/bindgen" --version
cp "$host_tools/.crates.toml" host-tools-crates.toml

host_version=$(g++ -dumpversion)
host_machine=$(g++ -dumpmachine)
export MOLI_HOST_CXXFLAGS="-nostdinc++ -isystem/usr/include/c++/$host_version -isystem/usr/include/$host_machine/c++/$host_version -isystem/usr/include/c++/$host_version/backward"
export MOLI_TARGET_CXXFLAGS="$MOLI_HOST_CXXFLAGS"
export MOLI_TARGET_LDFLAGS='-static-libstdc++ -static-libgcc'
export CC=clang CXX=clang++ CXXSTDLIB=''
export CXXFLAGS="$MOLI_TARGET_CXXFLAGS"
if [[ "$TARGET" == *-musl ]]; then
  export RUSTY_V8_MUSL_SYSROOT=/work/target-sysroot
  # Discover paths from the actual Alpine GCC package, never host GCC headers.
  includes=(/work/target-sysroot/usr/include/c++/*)
  test "${#includes[@]}" -eq 1
  cpp_include=${includes[0]}
  machine_includes=("$cpp_include"/*-alpine-linux-musl)
  test "${#machine_includes[@]}" -eq 1
  test -d "${machine_includes[0]}"
  export MOLI_TARGET_CXXFLAGS="-nostdinc++ -isystem$cpp_include -isystem${machine_includes[0]} -isystem$cpp_include/backward"
  runtime=(/work/target-sysroot/usr/lib/gcc/*-alpine-linux-musl/*/libstdc++.a)
  # Alpine may put the public static archive directly in /usr/lib.
  if [[ -f /work/target-sysroot/usr/lib/libstdc++.a ]]; then
    runtime=(/work/target-sysroot/usr/lib/libstdc++.a)
  fi
  test "${#runtime[@]}" -eq 1
  test -f "${runtime[0]}"
  sha256sum "${runtime[0]}" > target-runtime.sha256
  export CXXFLAGS="--sysroot=$RUSTY_V8_MUSL_SYSROOT $MOLI_TARGET_CXXFLAGS"
  export CFLAGS="--sysroot=$RUSTY_V8_MUSL_SYSROOT"
  cp target-sysroot/moli-apk-packages.txt target-packages.txt
else
  sha256sum "$(g++ -print-file-name=libstdc++.a)" > target-runtime.sha256
  dpkg-query -W > target-packages.txt
fi
export BINDGEN_EXTRA_CLANG_ARGS="$CXXFLAGS"
export V8_FROM_SOURCE=1 RUSTY_V8_MOLI_LIBSTDCXX=1
export GN_ARGS='use_custom_libcxx_for_host=false use_glib=false clang_version="23" rust_bindgen_root="/work/target/moli-host-tools"'
git submodule status --recursive > git_submodule_status.txt
cargo build --locked --release --no-default-features --lib --target "$TARGET"
sha256sum "$host_tools/bin/bindgen" "$host_tools/bin/rustfmt" > host-tools.sha256

# Same archive and bindings locations used by upstream ci.yml, renamed only
# at the publication boundary to prevent cross-variant cache collisions.
mkdir -p dist
archive="librusty_v8_moli_libstdcxx_release_${TARGET}.a.gz"
binding="src_binding_moli_libstdcxx_release_${TARGET}.rs"
gzip -n -c "target/$TARGET/release/gn_out/obj/librusty_v8.a" > "dist/$archive"
cp "target/$TARGET/release/gn_out/src_binding.rs" "dist/$binding"
cp "target/$TARGET/release/gn_out/args.gn" dist/args.gn
cp git_submodule_status.txt target-runtime.sha256 target-packages.txt debian-image.json dist/
cp compiler-packages.txt compiler-runtime.sha256 compiler-runtime-headers.txt dist/
cp host-tools.sha256 host-tools-crates.toml dist/
cp -r compiler-notices dist/
cp third_party/rust-toolchain/.moli-toolchain-inputs dist/rust-toolchain-inputs.txt
cp third_party/rust-toolchain/share/doc/rust/COPYRIGHT*.html dist/compiler-notices/
cp -r third_party/rust-toolchain/share/doc/rust/licenses dist/compiler-notices/rust-licenses
if [[ "$TARGET" == *-musl ]]; then cp alpine-image.json dist/; fi
notices="moli-v8-native-notices-${TARGET}.tar.gz"
notice_inputs=()
for package in "${llvm_packages[@]}"; do
  notice_inputs+=(--extra "/usr/share/doc/$package/copyright")
done
python3 tools/moli_libstdcxx/collect_notices.py \
  --output "dist/$notices" --rust-sysroot /work/third_party/rust-toolchain \
  "${notice_inputs[@]}"
{
  printf 'release_tag=v152.2.0-moli-sdk-libstdcxx.1\n'
  printf 'upstream_release=v152.2.0\nupstream_commit=2768994f664e8a6e3aba27503606c58339136e2a\n'
  printf 'fork_base=ef7a55c0c71ae904b1f963aa33d6d0076168a1b5\n'
  printf 'producer_commit=%s\ntarget=%s\nrun_id=%s\nrun_attempt=%s\n' "$GITHUB_SHA" "$TARGET" "$GITHUB_RUN_ID" "$GITHUB_RUN_ATTEMPT"
  printf 'rust_cross_language_thin_lto=false\nllvm_package_origin=https://apt.llvm.org/bookworm/\n'
  rustc -Vv
  third_party/rust-toolchain/bin/rustc -Vv
  "$host_tools/bin/bindgen" --version
  "$host_tools/bin/rustfmt" --version
  clang++ --version
  g++ --version
  dpkg-query -W
} > dist/provenance.txt
(cd dist && sha256sum "$archive" "$binding" "$notices" args.gn git_submodule_status.txt target-runtime.sha256 target-packages.txt debian-image.json provenance.txt compiler-packages.txt compiler-runtime.sha256 compiler-runtime-headers.txt rust-toolchain-inputs.txt host-tools.sha256 host-tools-crates.toml compiler-notices/*.* compiler-notices/rust-licenses/* > SHA256SUMS)
