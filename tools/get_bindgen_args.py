import argparse
import json
import os

parser = argparse.ArgumentParser(description='Generate args for bindgen')
parser.add_argument('--gn-out', help='GN out directory')
parser.add_argument('--moli-ext', action='store_true', help='Use the native bridge target ABI')
args = parser.parse_args()

with open(os.path.join(args.gn_out, 'project.json')) as project_json:
    project = json.load(project_json)

target = project['targets']['//:rusty_v8' if args.moli_ext else '//v8:v8_headers']

if not args.moli_ext:
    assert '//v8:cppgc_headers' in target['deps']

moli_ext = args.moli_ext
args = []

for define in target['defines']:
    args.append(f'-D{define}')

if moli_ext:
    root = project['build_settings']['root_path']
    for include in target['include_dirs']:
        if include.startswith('//'):
            include = os.path.join(root, include[2:])
        assert os.path.isabs(include), f'Unexpected GN include path: {include}'
        args.append(f'-I{include}')

print('\0'.join(args), end="")
