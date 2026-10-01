#!/usr/bin/env python3
"""Export and verify explicit, pinned binary inputs for Astra source builds."""
from pathlib import Path
import argparse
import hashlib
import json
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / 'script/runtime-kit.lock.json'

def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

def inventory(root):
    files, links = {}, {}
    for p in sorted(root.rglob('*')):
        relative = str(p.relative_to(root))
        if p.is_symlink():
            if not p.resolve().is_relative_to(root.resolve()) or not p.resolve().exists():
                raise RuntimeError('Escaping or broken dependency link: ' + relative)
            links[relative] = str(p.readlink())
        elif p.is_file():
            files[relative] = digest(p)
    return files, links

def verify(kit, lock_path=LOCK):
    kit = Path(kit).resolve()
    expected = json.loads(lock_path.read_text())
    if digest(kit / 'kit.json') != expected['manifest_sha256']:
        raise RuntimeError('Dependency-kit manifest differs from the source-controlled pin.')
    manifest = json.loads((kit / 'kit.json').read_text())
    files, links = inventory(kit / 'Contents')
    if files != manifest['files'] or links != manifest['symlinks']:
        raise RuntimeError('Dependency kit is incomplete or modified.')
    return manifest

def export(app, destination):
    if destination.exists():
        raise RuntimeError('Refusing to overwrite an existing dependency kit.')
    subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(app)],check=True)
    source = app / 'Contents'
    runtime = json.loads((source / 'Resources/AstraRuntime.json').read_text())
    for name, value in runtime['files'].items():
        if digest(source/name) != value:
            raise RuntimeError('Accepted runtime hash mismatch: '+name)
    destination.mkdir(parents=True)
    contents = destination / 'Contents'
    contents.mkdir()
    selected = ['Frameworks','Resources/qemu','Resources/vulkan','Resources/RuntimeNotices',
                'Resources/CocoaSpice_CocoaSpiceRenderer.bundle','Resources/Astra Guest Tools.iso',
                'Resources/AstraRuntime.json','Resources/AstraDXMT.json','MacOS/AstraRenderServer','Info.plist']
    for name in selected:
        p=source/name; target=contents/name; target.parent.mkdir(parents=True,exist_ok=True)
        if p.is_dir(): shutil.copytree(p,target,symlinks=True)
        else: shutil.copy2(p,target)
    files,links=inventory(contents)
    manifest={'schema':1,'kit_id':'accepted-standalone-20260925','origin':runtime['origin'],
              'policy':'Pinned accepted runtime, native renderer/worker, firmware, shaders and guest media. GUI and engine are rebuilt from source.',
              'source_provenance':'artifacts/reference/utm-5.0.5-dependency-sources.txt',
              'graphics_baseline':'vendor/graphics/source-state.json; current graphics trees contain unshipped experiments',
              'full_native_rebuild_demonstrated':False,'files':files,'symlinks':links}
    (destination/'kit.json').write_text(json.dumps(manifest,indent=2,sort_keys=True)+'\n')
    if LOCK.exists():
        if json.loads(LOCK.read_text())['manifest_sha256'] != digest(destination/'kit.json'):
            raise RuntimeError('New kit differs from the existing pin; review explicitly before replacing the lock.')
    else:
        LOCK.write_text(json.dumps({'schema':1,'kit_id':manifest['kit_id'],'manifest_sha256':digest(destination/'kit.json'),
                                   'default_directory':'artifacts/runtime-kits/accepted-20260925'},indent=2)+'\n')
    verify(destination)
    print(json.dumps({'result':'PASS','kit':str(destination),'files':len(files),'symlinks':len(links)}))

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--export-app',type=Path)
    parser.add_argument('--destination',type=Path)
    parser.add_argument('--verify',type=Path)
    args=parser.parse_args()
    if args.verify:
        result=verify(args.verify);print(json.dumps({'result':'PASS','files':len(result['files'])}))
    elif args.export_app and args.destination: export(args.export_app,args.destination)
    else: parser.error('Use --verify KIT or --export-app APP --destination NEW_DIRECTORY')
if __name__=='__main__':main()
