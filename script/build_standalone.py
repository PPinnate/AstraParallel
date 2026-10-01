#!/usr/bin/env python3
"""Build Astra with a pinned private runtime; never rebuild the graphics forks."""
from collections import deque
from contextlib import ExitStack
from datetime import datetime, timezone
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
from runtime_kit import verify as verify_runtime_kit
from release_manifest import write_release

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / 'dist/Astra Parallel.app'
INPUT = BASE / 'Contents'
EVIDENCE = ROOT / 'artifacts/evidence/enhancements-20260927'
SYSTEM_PREFIXES = ('/System/Library/', '/usr/lib/')

def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)

def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

def load_commands(path):
    output = subprocess.check_output(['/usr/bin/otool', '-arch', 'arm64', '-l', str(path)], text=True)
    dependencies, rpaths = [], []
    for block in re.split(r'Load command \d+\n', output):
        command = re.search(r'^\s*cmd (\S+)', block, re.M)
        if not command:
            continue
        if command[1] in ('LC_LOAD_DYLIB', 'LC_LOAD_WEAK_DYLIB', 'LC_REEXPORT_DYLIB', 'LC_LOAD_UPWARD_DYLIB', 'LC_LAZY_LOAD_DYLIB'):
            dependencies.append(re.search(r'^\s*name (.+?) \(offset', block, re.M)[1])
        elif command[1] == 'LC_RPATH':
            rpaths.append(re.search(r'^\s*path (.+?) \(offset', block, re.M)[1])
    return dependencies, rpaths

def regular_files(path):
    return sorted(p for p in path.rglob('*') if p.is_file() and not p.is_symlink())

def resolve_dependency(name, loader, framework_roots):
    if name.startswith(SYSTEM_PREFIXES):
        return None
    if name.startswith('@rpath/'):
        candidates = [root / name[len('@rpath/'):] for root in framework_roots]
    elif name.startswith('@loader_path/'):
        candidates = [loader.parent / name[len('@loader_path/'):]]
    elif name.startswith('@executable_path/'):
        candidates = [loader.parent / name[len('@executable_path/'):]]
    else:
        candidates = [Path(name)]
    for candidate in candidates:
        if candidate.is_file():
            return candidate.resolve()
    raise RuntimeError('Unresolved runtime dependency: ' + name + ' from ' + str(loader))

def runtime_frameworks(source):
    manifest = source / 'Resources/AstraRuntime.json'
    if manifest.is_file():
        return json.loads(manifest.read_text())['frameworks']
    frameworks = source / 'Frameworks'
    base_frameworks = BASE / 'Contents/Frameworks'
    # EGL/GLES and MoltenVK are loaded dynamically rather than via LC_LOAD_DYLIB.
    seeds = [frameworks / (name + '.framework') / name for name in
             ['qemu-aarch64-softmmu', 'swtpm.0', 'EGL', 'GLESv2', 'MoltenVK']]
    seeds += [BASE / 'Contents/MacOS/AstraParallel', BASE / 'Contents/MacOS/AstraEngine',
              BASE / 'Contents/MacOS/AstraRenderServer', base_frameworks / 'AstraDXMT.dylib']
    queue, seen, names = deque(seeds), set(), set()
    while queue:
        path = queue.popleft().resolve()
        if path in seen:
            continue
        seen.add(path)
        if path.is_relative_to(frameworks.resolve()):
            first = path.relative_to(frameworks.resolve()).parts[0]
            if first.endswith('.framework'):
                names.add(first)
        dependencies, _ = load_commands(path)
        for name in dependencies:
            candidate = resolve_dependency(name, path, [frameworks, base_frameworks])
            if candidate:
                queue.append(candidate)
    return sorted(names)

def stage_runtime(contents):
    base_contents = INPUT
    if (base_contents / 'Resources/AstraRuntime.json').exists():
        source = base_contents
        prior = json.loads((source / 'Resources/AstraRuntime.json').read_text())
        for name, expected in prior['files'].items():
            if digest(source / name) != expected:
                raise RuntimeError('Existing private runtime changed: ' + name)
    else:
        source = Path(os.environ.get('ASTRA_IMPORT_UTM', '/Applications/UTM.app')) / 'Contents'
        info = plistlib.loads((source / 'Info.plist').read_bytes())
        if (info['CFBundleShortVersionString'], str(info['CFBundleVersion'])) != ('5.0.5', '124'):
            raise RuntimeError('Initial runtime import requires the tested UTM 5.0.5 (124).')
    names = runtime_frameworks(source)
    selected = []
    for name in names:
        destination = contents / 'Frameworks' / name
        shutil.copytree(source / 'Frameworks' / name, destination, symlinks=True)
        selected.append(destination)
    original_files = {str(path.relative_to(contents)): digest(path)
                      for directory in selected for path in regular_files(directory)}
    # Imported framework signatures may carry stale/relocated bundle seals.
    # Sign these private copies; never change anything inside installed UTM.
    for name in names:
        run('codesign', '--force', '--sign', '-', contents / 'Frameworks' / name)
    resources = contents / 'Resources'
    qemu = resources / 'qemu'
    qemu.mkdir()
    for item in (source / 'Resources/qemu').iterdir():
        # Keep small ROMs/keymaps, but only the ARM secure UEFI firmware used by
        # this VM. Other architectures and their firmware are unnecessary.
        if item.name == 'firmware' or (item.suffix == '.fd' and item.name not in ['edk2-aarch64-secure-code.fd', 'edk2-arm-vars.fd']):
            continue
        destination = qemu / item.name
        if item.is_dir(): shutil.copytree(item, destination, symlinks=True)
        else: shutil.copy2(item, destination)
    selected.append(qemu)
    vulkan = resources / 'vulkan/icd.d'
    vulkan.mkdir(parents=True)
    shutil.copy2(source / 'Resources/vulkan/icd.d/MoltenVK_icd.json', vulkan)
    selected.append(resources / 'vulkan')
    files = {}
    for directory in selected:
        for path in regular_files(directory):
            files[str(path.relative_to(contents))] = digest(path)
    manifest = {'schema': 1, 'origin': 'UTM 5.0.5 (124), pinned local runtime import',
                'frameworks': names, 'files': files, 'imported_framework_files': original_files,
                'resource_policy': 'ARM secure firmware plus small QEMU resources'}
    (resources / 'AstraRuntime.json').write_text(json.dumps(manifest, indent=2) + '\n')
    notices = resources / 'RuntimeNotices'
    notices.mkdir()
    if (source / 'Resources/RuntimeNotices').is_dir():
        shutil.copytree(source / 'Resources/RuntimeNotices', notices, dirs_exist_ok=True)
    for label, path in [('CocoaSpice-LICENSE', ROOT / 'vendor/CocoaSpice/LICENSE'),
                        ('DXMT-LICENSE', ROOT / 'third-party-licenses/dxmt/LICENSE'),
                        ('DXMT-COPYING.LIB', ROOT / 'third-party-licenses/dxmt/COPYING.LIB'),
                        ('virglrenderer-COPYING', ROOT / 'third-party-licenses/virglrenderer/COPYING'),
                        ('Astra-upstream-notices.md', ROOT / 'docs/upstream-notices.md'),
                        ('UTM-dependency-sources.txt', ROOT / 'docs/runtime-provenance.txt')]:
        if path.is_file(): shutil.copy2(path, notices / label)
    return manifest

def clean_build_rpaths(path):
    _, paths = load_commands(path)
    for value in paths:
        if value.startswith('/') and value != '/usr/lib/swift':
            run('/usr/bin/install_name_tool', '-delete_rpath', value, path)

def executable_code_hash(path):
    """Hash executable instruction sections, excluding loader/signature metadata."""
    # The accepted Astra helper is an arm64 Mach-O, not a universal binary.
    import struct
    data = path.read_bytes()
    if data[:4] != b'\xcf\xfa\xed\xfe':
        raise RuntimeError('Expected arm64 Mach-O helper.')
    ncmds = struct.unpack_from('<I', data, 16)[0]
    offset = 32
    hashes = {}
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', data, offset)
        if cmd == 0x19:  # LC_SEGMENT_64
            nsects = struct.unpack_from('<I', data, offset + 64)[0]
            for i in range(nsects):
                section = offset + 72 + i * 80
                name = data[section:section + 16].split(b'\0')[0].decode()
                segment = data[section + 16:section + 32].split(b'\0')[0].decode()
                length, file_offset = struct.unpack_from('<QI', data, section + 40)
                flags = struct.unpack_from('<I', data, section + 64)[0]
                if flags & (0x80000000 | 0x00000400):  # pure/some instructions
                    hashes[segment + ',' + name] = hashlib.sha256(data[file_offset:file_offset + length]).hexdigest()
        offset += size
    if not hashes:
        raise RuntimeError('No executable sections found.')
    return hashes

def verify_dependencies(contents):
    roots = [contents / 'Frameworks']
    candidates = [p for p in (contents / 'MacOS').iterdir() if p.is_file()]
    candidates += [p for p in regular_files(contents / 'Frameworks')
                   if p.open('rb').read(4) in (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xce\xfa\xed\xfe')]
    report = []
    for path in candidates:
        deps, paths = load_commands(path)
        for value in paths:
            if '/Applications/UTM.app' in value:
                raise RuntimeError('Installed UTM remains in a runtime search path: ' + str(path))
        for name in deps:
            if name.startswith(SYSTEM_PREFIXES):
                continue
            resolved = resolve_dependency(name, path, roots)
            if not resolved.is_relative_to(contents.resolve()):
                raise RuntimeError('External non-system runtime dependency: ' + name)
            report.append({'image': str(path.relative_to(contents)), 'dependency': name,
                           'resolved': str(resolved.relative_to(contents.resolve()))})
    return report

def main():
    global INPUT
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mode', default='--stage-ui')
    parser.add_argument('--runtime-kit', type=Path, default=os.environ.get('ASTRA_RUNTIME_KIT'))
    args = parser.parse_args()
    mode = args.mode
    if mode not in ['--stage-ui', '--standalone', '--build-only', 'run', '--verify', '--debug', '--logs', '--telemetry']:
        parser.error('Unsupported build mode')
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    default_kit = ROOT / 'artifacts/runtime-kits/accepted-20260925'
    kit_path = args.runtime_kit or (default_kit if default_kit.exists() else None)
    kit = None
    if kit_path:
        kit = verify_runtime_kit(kit_path)
        INPUT = kit_path.resolve() / 'Contents'
    else:
        # Explicit legacy fallback for established workspaces only. Fresh source
        # builds use the separately pinned kit and need no old app executable.
        if not BASE.exists():
            raise RuntimeError('Supply the pinned binary dependency kit with --runtime-kit or ASTRA_RUNTIME_KIT. See docs/release-inputs.md.')
        run('codesign', '--verify', '--deep', '--strict', BASE)
        print('Build input: existing signed app (legacy fallback). Export/retain a pinned runtime kit for clean builds.', flush=True)
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    bundle = ROOT / 'dist/standalone' / stamp / 'Astra Parallel.app'
    contents = bundle / 'Contents'
    contents.mkdir(parents=True)
    for name in ['MacOS', 'Frameworks', 'Resources']:
        (contents / name).mkdir()
    preserved = ['Frameworks/AstraDXMT.dylib', 'MacOS/AstraRenderServer', 'Resources/AstraDXMT.json']
    for name in preserved:
        shutil.copy2(INPUT / name, contents / name)
    shader = 'Resources/CocoaSpice_CocoaSpiceRenderer.bundle'
    shutil.copytree(INPUT / shader, contents / shader, symlinks=True)
    renderer = json.loads((contents / 'Resources/AstraDXMT.json').read_text())
    assert digest(contents / 'Frameworks/AstraDXMT.dylib') == renderer['sha256']
    assert digest(contents / 'MacOS/AstraRenderServer') == renderer['worker_sha256']
    manifest = stage_runtime(contents)
    tools_image = INPUT / 'Resources/Astra Guest Tools.iso'
    override = os.environ.get('ASTRA_GUEST_TOOLS_ISO')
    if override:
        tools_image = Path(override)
        expected_tools_hash = os.environ.get('ASTRA_GUEST_TOOLS_SHA256')
        if not expected_tools_hash or digest(tools_image) != expected_tools_hash:
            raise RuntimeError('An explicit guest-tools override requires its matching ASTRA_GUEST_TOOLS_SHA256 pin.')
    if not tools_image.is_file():
        raise RuntimeError('The pinned build inputs do not contain the guest-tools image.')
    shutil.copy2(tools_image, contents / 'Resources/Astra Guest Tools.iso')
    manifest['files']['Resources/Astra Guest Tools.iso'] = digest(contents / 'Resources/Astra Guest Tools.iso')
    (contents / 'Resources/AstraRuntime.json').write_text(json.dumps(manifest, indent=2) + '\n')
    worker = contents / 'MacOS/AstraRenderServer'
    worker_code_before = executable_code_hash(worker)
    clean_build_rpaths(worker)
    if '@executable_path/../Frameworks' not in load_commands(worker)[1]:
        run('/usr/bin/install_name_tool', '-add_rpath', '@executable_path/../Frameworks', worker)
    run('codesign', '--force', '--sign', '-', '--entitlements', ROOT / 'script/render_worker.entitlements', worker)
    assert executable_code_hash(worker) == worker_code_before
    renderer['standalone_base_worker_sha256'] = renderer['worker_sha256']
    renderer['worker_sha256'] = digest(worker)
    renderer['standalone_worker_change'] = 'Bundle-relative library search paths and signature only; executable sections unchanged'
    (contents / 'Resources/AstraDXMT.json').write_text(json.dumps(renderer, indent=2) + '\n')
    env = dict(os.environ)
    env.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
    env['ASTRA_BUILD_FRAMEWORKS'] = str(contents / 'Frameworks')
    env['CLANG_MODULE_CACHE_PATH'] = str(ROOT / '.cache/clang')
    env['SWIFTPM_MODULECACHE_OVERRIDE'] = str(ROOT / '.cache/swift')
    run('xcrun', 'swift', 'build', '--disable-sandbox', '--cache-path', ROOT / '.cache/swiftpm', '--product', 'AstraParallel', env=env, cwd=ROOT)
    bin_dir = Path(subprocess.check_output(['xcrun', 'swift', 'build', '--disable-sandbox', '--cache-path', str(ROOT / '.cache/swiftpm'), '--show-bin-path'], env=env, cwd=ROOT, text=True).strip())
    shutil.copy2(bin_dir / 'AstraParallel', contents / 'MacOS/AstraParallel')
    frameworks = contents / 'Frameworks'
    run('xcrun', 'clang', '-arch', 'arm64', '-dynamiclib', '-Wall', '-Wextra', '-I', ROOT / 'Sources/AstraPlatform/include',
        ROOT / 'Sources/AstraPlatform/GPoll.c', ROOT / 'Sources/AstraPlatform/GPollInterpose.c', '-F', frameworks,
        '-framework', 'glib-2.0.0', '-Wl,-install_name,@rpath/AstraPolling.dylib', '-Wl,-rpath,@loader_path',
        '-o', frameworks / 'AstraPolling.dylib', env=env)
    run('codesign', '--force', '--sign', '-', frameworks / 'AstraPolling.dylib')
    run('xcrun', 'clang', '-arch', 'arm64', '-g', '-Wall', '-Wextra', '-fobjc-arc', ROOT / 'Sources/AstraEngine/main.m',
        frameworks / 'AstraPolling.dylib', '-I', ROOT / 'Sources/AstraPlatform/include', '-framework', 'Foundation',
        '-F', frameworks, '-framework', 'glib-2.0.0',
        '-Wl,-sectcreate,__TEXT,__info_plist,' + str(ROOT / 'script/engine-info.plist'),
        '-Wl,-rpath,@executable_path/../Frameworks', '-o', contents / 'MacOS/AstraEngine', env=env)
    symbols = contents / 'MacOS/AstraEngine.dSYM'
    if symbols.exists():
        symbol_directory = EVIDENCE / ('symbols-' + stamp)
        symbol_directory.mkdir()
        symbols.rename(symbol_directory / symbols.name)
    clean_build_rpaths(contents / 'MacOS/AstraParallel')
    info = plistlib.loads((INPUT / 'Info.plist').read_bytes())
    info.pop('AstraWorkspace', None)
    info.update(CFBundleShortVersionString='0.3.0', CFBundleVersion='0.3.0', AstraFeatureBuild='reliability-integration-v1',
                AstraStandaloneRuntime=True, AstraBuildTimestamp=stamp)
    (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
    (ROOT / '.build/engine').mkdir(parents=True, exist_ok=True)
    run('python3', ROOT / 'script/sign_engine.py', contents / 'MacOS/AstraEngine')
    release = write_release(ROOT, contents, kit, env)
    run('codesign', '--force', '--sign', '-', '--entitlements', ROOT / 'script/gui.entitlements', bundle)
    run('codesign', '--verify', '--deep', '--strict', bundle)
    dependencies = verify_dependencies(contents)
    assert digest(contents / 'Frameworks/AstraDXMT.dylib') == digest(INPUT / 'Frameworks/AstraDXMT.dylib')
    assert executable_code_hash(worker) == executable_code_hash(INPUT / 'MacOS/AstraRenderServer')
    for name, expected in manifest['files'].items():
        assert digest(contents / name) == expected, name
    report = {'result': 'PASS_PACKAGED_RUNTIME_TEST_PENDING', 'bundle': str(bundle), 'created_at': stamp,
              'framework_count': len(manifest['frameworks']), 'runtime_bytes': sum((contents / p).stat().st_size for p in manifest['files']),
              'application_bytes': sum(p.stat().st_size for p in regular_files(bundle)),
              'graphics_preserved': {name: digest(contents / name) for name in preserved},
              'worker_executable_sections_unchanged': worker_code_before,
              'gui_sha256': digest(contents / 'MacOS/AstraParallel'), 'codesign_verify': 'PASS',
              'source_identity_sha256': release['source_identity_sha256'], 'runtime_kit': str(kit_path) if kit_path else None,
              'non_system_dependencies': dependencies, 'vm_started': False, 'utm_modified': False}
    (EVIDENCE / ('package-' + stamp + '.json')).write_text(json.dumps(report, indent=2) + '\n')
    (EVIDENCE / 'latest-package.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({k: report[k] for k in ['result', 'bundle', 'framework_count', 'runtime_bytes', 'application_bytes']}, indent=2), flush=True)
    if mode in ['--stage-ui', '--standalone']:
        return
    # The normal Run/build-only path preserves the existing VM-lock guard and
    # keeps a dated rollback bundle. The staged preview mode never reaches here.
    run('python3', ROOT / 'script/stop_idle_app.py')
    import fcntl
    with ExitStack() as stack:
        legacy_lock = ROOT / 'vm/windows-arm/.run.lock'
        if legacy_lock.exists():
            lock = stack.enter_context(legacy_lock.open('r+'))
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        rollback = ROOT / 'dist/rollback' / ('pre-standalone-' + stamp)
        rollback.mkdir(parents=True)
        staging = Path(tempfile.mkdtemp(prefix='.standalone-install-', dir=ROOT / 'dist'))
        staged_app = staging / BASE.name
        shutil.copytree(bundle, staged_app, symlinks=True)
        run('codesign', '--verify', '--deep', '--strict', staged_app)
        had_base = BASE.exists()
        if had_base:
            BASE.rename(rollback / BASE.name)
        try:
            staged_app.rename(BASE)
        except Exception:
            if had_base: (rollback / BASE.name).rename(BASE)
            raise
        staging.rmdir()
    if mode == '--build-only':
        return
    if mode == '--debug':
        run('xcrun', 'lldb', '--', BASE / 'Contents/MacOS/AstraParallel', env=env)
    else:
        run('/usr/bin/open', '-n', BASE)
        if mode in ['--logs', '--telemetry']:
            run('/usr/bin/log', 'stream', '--info', '--style', 'compact', '--predicate', 'process == "AstraParallel"')

if __name__ == '__main__':
    main()
