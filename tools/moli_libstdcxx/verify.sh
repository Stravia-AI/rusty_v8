#!/bin/sh
set -eu

# No glibc compatibility layer: musl verification executes only Alpine tools
# and the native musl Rust toolchain. Rebuild the public-header extensions as
# an actual prebuilt-archive consumer, not against the producer's V8 internals.
if [ -f /etc/alpine-release ]; then
  apk add --no-cache ca-certificates curl g++ linux-headers libstdc++-dev binutils bash
else
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends ca-certificates curl g++ binutils
fi
curl -fsSL https://sh.rustup.rs -o /tmp/rustup.sh
sh /tmp/rustup.sh -y --profile minimal --default-host "$TARGET" --default-toolchain none
export PATH="/root/.cargo/bin:$PATH"
export RUSTUP_TOOLCHAIN=1.91.0
export CARGO_BUILD_JOBS=2
mkdir -p /tmp/v8-consumer
cp Cargo.toml Cargo.lock build.rs rust-toolchain.toml /tmp/v8-consumer/
cp -a src examples benches tests gen moli_v8_include /tmp/v8-consumer/
mkdir -p /tmp/v8-consumer/third_party/icu/common
cp third_party/icu/common/icudtl.dat /tmp/v8-consumer/third_party/icu/common/
cd /tmp/v8-consumer
rustup toolchain install "$RUSTUP_TOOLCHAIN" --profile minimal --no-self-update
rustup target add "$TARGET"
export RUSTY_V8_ARCHIVE="/work/dist/librusty_v8_moli_libstdcxx_release_${TARGET}.a.gz"
export RUSTY_V8_SRC_BINDING_PATH="/work/dist/src_binding_moli_libstdcxx_release_${TARGET}.rs"
export RUSTY_V8_ARCHIVE_SHA256=$(sha256sum "$RUSTY_V8_ARCHIVE" | cut -d ' ' -f 1)
export RUSTY_V8_MOLI_LIBSTDCXX=1
export CXXSTDLIB=''
expected_runtime=$(cut -d ' ' -f 1 /work/dist/target-runtime.sha256)
actual_runtime=$(sha256sum "$(g++ -print-file-name=libstdc++.a)" | cut -d ' ' -f 1)
test "$actual_runtime" = "$expected_runtime"
atomic_runtime=$(g++ -print-file-name=libatomic.a)
test "$(sha256sum "$atomic_runtime" | cut -d ' ' -f 1)" = "$(cut -d ' ' -f 1 /work/dist/target-atomic.sha256)"
# Rust's compiler builtins do not provide every C++ helper: ARM JIT code
# requires the target GCC runtime's __clear_cache implementation.
compiler_runtime=$(g++ -print-file-name=libgcc.a)
test -f "$compiler_runtime"
sha256sum "$compiler_runtime" > /work/dist/native-compiler-runtime.sha256
export RUSTFLAGS="-L native=$(dirname "$(g++ -print-file-name=libstdc++.a)") -L native=$(dirname "$(g++ -print-file-name=libgcc_eh.a)") -L native=$(dirname "$atomic_runtime") -l static=stdc++ -l static=gcc_eh -l static=gcc"
cargo build --locked --release --no-default-features --target "$TARGET" --example hello_world
binary="target/$TARGET/release/examples/hello_world"
"$binary" > /work/dist/native-hello-world.txt
test "$(cat /work/dist/native-hello-world.txt)" = "$(printf 'Hello World!\n3 + 4 = 7')"
for scenario in \
  backing_store_segfault shared_array_buffer_allocator script_compiler_source \
  compiled_wasm_module wasm_streaming_callback inspector_string_buffer \
  inspector_dispatch_protocol_message inspector_release_object_group
do
  cargo test --locked --release --no-default-features --target "$TARGET" \
    --test test_api "$scenario" -- --exact \
    > "/work/dist/native-test-$scenario.txt" 2>&1 || {
      status=$?
      cat "/work/dist/native-test-$scenario.txt"
      exit "$status"
    }
done
readelf -d "$binary" > /work/dist/native-dynamic-section.txt
readelf --version-info "$binary" > /work/dist/native-symbol-versions.txt
# readelf output remains evidence even when a musl executable is fully static.
needed=$(sed -n '/NEEDED/p' /work/dist/native-dynamic-section.txt)
case "$needed" in
  *libstdc++*|*libc++*|*libgcc_s*|*libatomic*)
    echo 'Native smoke binary has a dynamic C++ runtime dependency' >&2
    exit 1 ;;
esac
cd /work/dist
python3 - <<'PY'
import pathlib
import subprocess

# A successful producer already has report hashes. Replace only the reports
# generated above; keep immutable producer input hashes for the final check.
reports = ['native-hello-world.txt', 'native-dynamic-section.txt',
           'native-symbol-versions.txt', 'native-compiler-runtime.sha256']
reports.extend(str(path) for path in sorted(pathlib.Path('.').glob('native-test-*.txt')))
updated = subprocess.check_output(['sha256sum', *reports], text=True).splitlines()
names = {line.split(maxsplit=1)[1] for line in updated}
manifest = pathlib.Path('SHA256SUMS')
retained = [line for line in manifest.read_text().splitlines()
            if line.split(maxsplit=1)[1] not in names]
manifest.write_text('\n'.join([*retained, *updated]) + '\n', newline='\n')
subprocess.run(['sha256sum', '--check', 'SHA256SUMS'], check=True)
PY
