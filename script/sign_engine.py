#!/usr/bin/env python3
"""Sign Astra's engine as a sandbox parent for UTM's inherit-only render worker."""
from pathlib import Path
import plistlib
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
entitlements = {
    'com.apple.security.app-sandbox': True,
    'com.apple.security.hypervisor': True,
    # This is Astra's new, isolated shared-memory namespace, never UTM's group.
    'com.apple.security.application-groups': ['group.local.astra'],
    'com.apple.security.network.client': True,
    'com.apple.security.network.server': True,
}
output = root/'.build/engine/engine-sandbox.entitlements'
output.write_bytes(plistlib.dumps(entitlements))
subprocess.run(['/usr/bin/codesign','--force','--sign','-','--identifier','local.astra.engine',
                '--entitlements',str(output),sys.argv[1]], check=True)
