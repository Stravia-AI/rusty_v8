from v8_deps import deps
from download_file import DownloadUrl
import platform
import os
import tempfile
import tarfile
import sys

DIR = 'third_party/rust-toolchain'
SENTINEL = f'{DIR}/.rusty_v8_version'

host_os = platform.system().lower()
if host_os == "darwin":
    host_os = "mac"
elif host_os == "windows":
    host_os = "win"

host_cpu = platform.machine().lower()
if host_cpu == "x86_64":
    host_cpu = "x64"
elif host_cpu == "aarch64":
    host_cpu = "arm64"

eval_globals = {
    'host_os': host_os,
    'host_cpu': host_cpu,
}

# The SDK builds on native Linux hosts. Chromium's Linux DEPS object is x64
# only; use a separately pinned, genuine nightly distribution for this variant.
if os.environ.get('RUSTY_V8_MOLI_LIBSTDCXX') == '1':
    import hashlib
    import shutil
    import subprocess

    if host_os != 'linux' or host_cpu not in ('x64', 'arm64'):
        raise RuntimeError('The SDK Rust toolchain requires a native Linux host')
    arch = 'x86_64' if host_cpu == 'x64' else 'aarch64'
    host = f'{arch}-unknown-linux-gnu'
    target = os.environ['TARGET']
    if target not in (host, f'{arch}-unknown-linux-musl'):
        raise RuntimeError(f'SDK target {target} does not match host {host}')
    date = '2026-06-17'
    revision = '9e2abe0c6ab27fcbb95c30695188a75776e2feb1'
    hashes = {
        ('rustc', 'aarch64-unknown-linux-gnu'): '01e3828f531febb7aa18e3c3c55b93b005d6a5efd1ae95a0f4080caa8e364b09',
        ('rustc', 'x86_64-unknown-linux-gnu'): '022c0f2c4b708ab57a8115fac1e91006fb20463d2077c24203ce5426cfba6c33',
        ('rust-std', 'aarch64-unknown-linux-gnu'): '3bfd9b15803c4d448658bccaf6f20fa99cf2a7cf3d4553141ac846d4c618a51e',
        ('rust-std', 'aarch64-unknown-linux-musl'): '8df1e44bda7342d859d10e77d0da2b86877d63b169d2eaed0e68bd4f2a390018',
        ('rust-std', 'x86_64-unknown-linux-gnu'): 'd24d693348498f241da8d8878b6dbf760e99d61b9949306a74c82f676f8ec59f',
        ('rust-std', 'x86_64-unknown-linux-musl'): '1931e5500bc882a0d3df5fac1d1b80a78a9e9d673b5c6fed210604d45ee1e721',
        ('rustfmt', 'x86_64-unknown-linux-gnu'): 'f6cb553a03c2d8a326f9d6714faf07096f25a10c49b02a135fe55841bfafb743',
        ('rustfmt', 'aarch64-unknown-linux-gnu'): '37b179f04aa6c7e50daf52c98444ed5c1ae406674395ace68f1d4a2071e1a964',
    }
    components = [('rustc', host), ('rust-std', host), ('rustfmt', host)]
    if target != host:
        components.append(('rust-std', target))
    inputs = f'nightly={date}\nrevision={revision}\n'
    for package, triple in components:
        name = f'{package}-nightly-{triple}.tar.xz'
        inputs += f'{hashes[package, triple]}  https://static.rust-lang.org/dist/{date}/{name}\n'
    sdk_sentinel = f'{DIR}/.moli-toolchain-inputs'
    try:
        with open(sdk_sentinel) as f:
            if f.read() == inputs:
                sys.exit(0)
    except FileNotFoundError:
        pass
    # A toolchain switch must not retain incompatible stdlib metadata.
    if os.path.exists(DIR):
        shutil.rmtree(DIR)
    for package, triple in components:
        name = f'{package}-nightly-{triple}'
        url = f'https://static.rust-lang.org/dist/{date}/{name}.tar.xz'
        with tempfile.TemporaryDirectory() as staging:
            archive_path = os.path.join(staging, 'component.tar.xz')
            with open(archive_path, 'w+b') as f:
                DownloadUrl(url, f)
                f.seek(0)
                digest = hashlib.file_digest(f, 'sha256').hexdigest()
                if digest != hashes[package, triple]:
                    raise RuntimeError(f'SHA256 mismatch for {url}: {digest}')
                f.seek(0)
                with tarfile.open(mode='r:xz', fileobj=f) as archive:
                    archive.extractall(staging)
            subprocess.run(['bash', os.path.join(staging, name, 'install.sh'),
                            f'--prefix={os.path.abspath(DIR)}',
                            '--disable-ldconfig'], check=True)
    version = subprocess.check_output([f'{DIR}/bin/rustc', '-Vv'], text=True)
    if f'commit-hash: {revision}\n' not in version or f'host: {host}\n' not in version:
        raise RuntimeError(f'Unexpected SDK Rust compiler: {version}')
    with open(sdk_sentinel, 'w') as f:
        f.write(inputs)
    sys.exit(0)

# Switching back to the upstream variant must not mix nightly stdlib metadata
# into the unchanged DEPS-selected package.
if os.path.isfile(f'{DIR}/.moli-toolchain-inputs'):
    import shutil
    shutil.rmtree(DIR)

dep = deps[DIR]
obj = next(obj for obj in dep['objects'] if eval(obj['condition'], eval_globals))
bucket = dep['bucket']
name = obj['object_name']
url = f'https://storage.googleapis.com/{bucket}/{name}'


def EnsureDirExists(path):
    if not os.path.exists(path):
        os.makedirs(path)


def DownloadAndUnpack(url, output_dir):
    """Download an archive from url and extract into output_dir."""
    with tempfile.TemporaryFile() as f:
        DownloadUrl(url, f)
        f.seek(0)
        EnsureDirExists(output_dir)
        with tarfile.open(mode='r:xz', fileobj=f) as z:
            z.extractall(path=output_dir)

try:
    with open(SENTINEL, 'r') as f:
        if f.read() == url:
            print(f'{DIR}: already downloaded')
            sys.exit()
except FileNotFoundError:
    pass

DownloadAndUnpack(url, DIR)

with open(SENTINEL, 'w') as f:
    f.write(url)
