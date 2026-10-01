#!/usr/bin/env python3
"""Package the verified guest payload and a double-click Windows installer."""
import base64
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
base = ROOT / 'artifacts/guest-tools'
payload = base / 'payload'
manifest = json.loads((payload / 'payload-manifest.json').read_text())
for entry in manifest['files']:
    assert hashlib.sha256((payload / entry['path']).read_bytes()).hexdigest() == entry['sha256'], entry['path']
script = (ROOT / 'script/guest_install_astra_tools.ps1').read_text()
# CMD lines have an 8191-character limit. Keep the bootstrap short; the fixed
# installer source lives on the read-only, integrity-checked tools disc.
bootstrap = "& ([scriptblock]::Create([IO.File]::ReadAllText((Join-Path $env:ASTRA_TOOLS_ROOT 'installer-source.ps1'))))"
encoded = base64.b64encode(bootstrap.encode('utf-16le')).decode()
launcher = '''@echo off\r
setlocal\r
set "ASTRA_TOOLS_ROOT=%~dp0"\r
set "ASTRA_TOOLS_CHECK_ONLY=0"\r
if /i "%~1"=="--check" set "ASTRA_TOOLS_CHECK_ONLY=1"\r
"%SystemRoot%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe" -NoProfile -EncodedCommand ''' + encoded + '''\r
set "ASTRA_RESULT=%ERRORLEVEL%"\r
if "%ASTRA_TOOLS_CHECK_ONLY%"=="1" exit /b %ASTRA_RESULT%\r
if not "%ASTRA_RESULT%"=="0" echo Installation did not complete. Review the message above before retrying.\r
pause\r
exit /b %ASTRA_RESULT%\r
'''
if len(encoded) > 7000:
    raise SystemExit('Encoded installer exceeds the bounded command-line budget.')
(payload / 'Install Astra Tools.cmd').write_bytes(launcher.encode('ascii'))
(payload / 'installer-source.ps1').write_text(script)
(payload / 'README.txt').write_text('Astra Guest Tools\n\nOpen Install Astra Tools.cmd, approve the Windows administrator prompt, then restart Windows.\nDuring Windows setup, network drivers are in Drivers\\Network.\nThis package does not alter game/launcher files, anti-cheat settings, Secure Boot, or Windows signing policy.\nThe supported guest is Windows 11 ARM64 under Astra.\n')
image = base / 'Astra Guest Tools.iso'
temporary = base / 'Astra Guest Tools.building.iso'
subprocess.run(['/usr/bin/hdiutil','makehybrid','-iso','-joliet','-default-volume-name','Astra Guest Tools',
                '-o',str(temporary),str(payload)],check=True)
temporary.replace(image)
report = {'image':str(image),'sha256':hashlib.sha256(image.read_bytes()).hexdigest(),'bytes':image.stat().st_size,
          'payload_files':len(manifest['files']),'installer_source_sha256':hashlib.sha256(script.encode()).hexdigest()}
(base/'media.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
