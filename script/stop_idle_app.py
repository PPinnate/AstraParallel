#!/usr/bin/env python3
"""Refuse app replacement while its GUI or helpers remain open, for any VM path."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
executables = root / 'dist/Astra Parallel.app/Contents/MacOS'
# The old workspace lock cannot protect user-selected machines. Inspect the
# actual executable identities and fail closed, without killing an active GUI
# or a helper that could still own a guest disk or TPM file.
rows = subprocess.check_output(['/bin/ps','-axo','pid=,comm='],text=True).splitlines()
active=[]
for row in rows:
    parts=row.strip().split(None,1)
    if len(parts)==2 and Path(parts[1]).parent == executables:
        active.append(parts[0])
if active:
    raise SystemExit('Close Astra and wait for its VM helpers to exit before replacing the canonical app. Use --stage-ui to build a separate preview while it is open.')
