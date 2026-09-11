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
printf '%s\n' 'deb [signed-by=/usr/share/keyrings/llvm.gpg] https://apt.llvm.org/bookworm/ llvm-toolchain-bookworm-21 main' > /etc/apt/sources.list.d/llvm.list
apt-get update
apt-get install -y --no-install-recommends clang-21 lld-21 libclang-21-dev
curl -fsSL https://sh.rustup.rs -o /tmp/rustup.sh
sh /tmp/rustup.sh -y --profile minimal --default-host "${TARGET%-*}-gnu" --default-toolchain none
export PATH="/root/.cargo/bin:/usr/lib/llvm-21/bin:$PATH"
export LIBCLANG_PATH=/usr/lib/llvm-21/lib
export RUSTY_V8_BINDGEN_RESOURCE_DIR=$(/usr/lib/llvm-21/bin/clang -print-resource-dir)
# Chromium's Rust toolchain expects its matching compiler-rt directory
# layout. Distro Clang's resource tree is not interchangeable with it.
export CLANG_BASE_PATH=/work/target/moli-clang
python3 tools/clang/scripts/update.py --output-dir "$CLANG_BASE_PATH"
export PATH="$CLANG_BASE_PATH/bin:$PATH"
export RUSTUP_TOOLCHAIN=1.91.0
export CARGO_BUILD_JOBS=2
git config --global --add safe.directory /work
rustup toolchain install "$RUSTUP_TOOLCHAIN" --profile minimal --no-self-update
rustup target add "$TARGET"

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
export GN_ARGS='use_custom_libcxx_for_host=false use_glib=false'
git submodule status --recursive > git_submodule_status.txt
cargo build --locked --release --no-default-features --lib --target "$TARGET"

# Same archive and bindings locations used by upstream ci.yml, renamed only
# at the publication boundary to prevent cross-variant cache collisions.
mkdir -p dist
archive="librusty_v8_moli_libstdcxx_release_${TARGET}.a.gz"
binding="src_binding_moli_libstdcxx_release_${TARGET}.rs"
gzip -n -c "target/$TARGET/release/gn_out/obj/librusty_v8.a" > "dist/$archive"
cp "target/$TARGET/release/gn_out/src_binding.rs" "dist/$binding"
cp "target/$TARGET/release/gn_out/args.gn" dist/args.gn
cp git_submodule_status.txt target-runtime.sha256 target-packages.txt debian-image.json dist/
if [[ "$TARGET" == *-musl ]]; then cp alpine-image.json dist/; fi
{
  printf 'release_tag=v152.2.0-moli-sdk-libstdcxx.1\n'
  printf 'upstream_release=v152.2.0\nupstream_commit=2768994f664e8a6e3aba27503606c58339136e2a\n'
  printf 'fork_base=ef7a55c0c71ae904b1f963aa33d6d0076168a1b5\n'
  printf 'producer_commit=%s\ntarget=%s\nrun_id=%s\nrun_attempt=%s\n' "$GITHUB_SHA" "$TARGET" "$GITHUB_RUN_ID" "$GITHUB_RUN_ATTEMPT"
  rustc -Vv
  clang++ --version
  g++ --version
  dpkg-query -W
} > dist/provenance.txt
(cd dist && sha256sum "$archive" "$binding" args.gn git_submodule_status.txt target-runtime.sha256 target-packages.txt debian-image.json provenance.txt > SHA256SUMS)
