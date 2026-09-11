"""Collect notices from the actual native producer tree, not the slim Cargo checkout."""
import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import re
import tarfile


LICENSE = re.compile(r"^(licen[sc]e|copying|notice|copyright)([._-]|$)", re.I)
ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--rust-sysroot', type=Path, required=True)
    parser.add_argument('--extra', type=Path, action='append', default=[])
    args = parser.parse_args()
    files = {}
    for tree in (ROOT / 'v8', ROOT / 'third_party'):
        if not tree.is_dir():
            raise RuntimeError(f'native source tree is absent: {tree}')
        for folder, directories, names in os.walk(tree, followlinks=False):
            directories[:] = sorted(name for name in directories if name not in {'.git', 'rust-toolchain', 'llvm-build'})
            for name in sorted(names):
                path = Path(folder) / name
                if LICENSE.match(name) and path.is_file() and not path.is_symlink():
                    files['source/' + path.relative_to(ROOT).as_posix()] = path
    if 'source/v8/LICENSE' not in files:
        raise RuntimeError('V8 source license is absent; submodules must be initialized')
    for name in ('LICENSE', 'LICENSE-MIT', 'LICENSE-APACHE'):
        path = ROOT / name
        if path.is_file():
            files['source/' + name] = path
    rust = args.rust_sysroot / 'share/doc/rust'
    copyright = rust / 'COPYRIGHT-library.html'
    if not copyright.is_file() or not (rust / 'licenses').is_dir():
        raise RuntimeError(f'Rust standard-library notices are absent: {rust}')
    files['rust-runtime/COPYRIGHT-library.html'] = copyright
    for path in sorted((rust / 'licenses').rglob('*')):
        if path.is_file() and not path.is_symlink():
            files['rust-runtime/' + path.relative_to(rust).as_posix()] = path
    for index, source in enumerate(args.extra):
        if not source.is_file():
            raise RuntimeError(f'native runtime notice is absent: {source}')
        files[f'native-runtime/{index}/{source.name}'] = source
    inventory = {}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('xb') as output, gzip.GzipFile(filename='', mode='wb', fileobj=output, mtime=0) as compressed, tarfile.open(fileobj=compressed, mode='w') as archive:
        for name, path in sorted(files.items()):
            content = path.read_bytes()
            inventory[name] = hashlib.sha256(content).hexdigest()
            entry = tarfile.TarInfo(name)
            entry.size = len(content)
            entry.mode = 0o644
            archive.addfile(entry, io.BytesIO(content))
        content = (json.dumps(inventory, indent=2, sort_keys=True) + '\n').encode()
        entry = tarfile.TarInfo('files.json')
        entry.size = len(content)
        entry.mode = 0o644
        archive.addfile(entry, io.BytesIO(content))
    print(f'Collected {len(inventory)} native notice files into {args.output}')


if __name__ == '__main__':
    main()
