#!/usr/bin/env python3
"""Record source, binary dependencies and toolchain identity for an Astra build."""
import hashlib
import json
from pathlib import Path
import subprocess

def digest(path):
    with path.open('rb') as stream: return hashlib.file_digest(stream,'sha256').hexdigest()

def write_release(root, contents, kit, environment):
    source_files={}
    for folder in ['Sources','vendor/CocoaSpice/Sources']:
        for p in sorted((root/folder).rglob('*')):
            if p.is_file() and not p.is_symlink() and p.suffix in ('.swift','.h','.c','.m','.metal'):
                source_files[str(p.relative_to(root))]=digest(p)
    for p in [root/'Package.swift',root/'vendor/CocoaSpice/Package.swift',*sorted((root/'script').glob('*.entitlements')),
              root/'script/build_standalone.py',root/'script/runtime_kit.py',root/'script/release_manifest.py',
              root/'script/build_and_run.sh',root/'script/sign_engine.py',root/'script/engine-info.plist',root/'script/stop_idle_app.py']:
        source_files[str(p.relative_to(root))]=digest(p)
    runtime=json.loads((contents/'Resources/AstraRuntime.json').read_text())
    graphics=json.loads((contents/'Resources/AstraDXMT.json').read_text())
    result={'schema':1,'version':'0.3.0','source_files':source_files,
        'source_identity_sha256':hashlib.sha256(json.dumps(source_files,sort_keys=True).encode()).hexdigest(),
        'runtime_kit':{'id':kit['kit_id'],'manifest_sha256':json.loads((root/'script/runtime-kit.lock.json').read_text())['manifest_sha256']} if kit else None,
        'components':{
            'app':{'identity':'Final signed executable SHA-256 is in the external package receipt; source identity above avoids a signature/manifest hash cycle.','build':'SwiftPM debug; source files above'},
            'engine':{'sha256':digest(contents/'MacOS/AstraEngine'),'source':'Sources/AstraEngine/main.m'},
            'runtime':{'origin':runtime['origin'],'manifest_sha256':digest(contents/'Resources/AstraRuntime.json')},
            'native_graphics':{'sha256':graphics['sha256'],'worker_sha256':graphics['worker_sha256'],'source_state_sha256':digest(root/'vendor/graphics/source-state.json'),'rebuild':'Preserved accepted binaries; development experiments excluded'},
            'guest_tools':{'sha256':digest(contents/'Resources/Astra Guest Tools.iso'),'graphics_build':'resource-convert-v1','installation_test':'Pending fresh Windows test'},
            'firmware':{name:value for name,value in runtime['files'].items() if name.endswith('.fd')},
        },
        'toolchain':{'xcode':subprocess.check_output(['xcodebuild','-version'],env=environment,text=True).strip(),
                     'swift':subprocess.check_output(['xcrun','swift','--version'],env=environment,text=True).strip()},
        'limits':['Pinned binary dependencies are required; this is not a complete source rebuild of QEMU/DXMT/guest drivers.',
                  'Ad hoc signed local build; no notarization or second-Mac claim.']}
    (contents/'Resources/AstraRelease.json').write_text(json.dumps(result,indent=2,sort_keys=True)+'\n')
    return result
