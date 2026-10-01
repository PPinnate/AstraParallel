import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SCRIPT=Path(__file__).resolve().parents[1]/'script/runtime_kit.py'
spec=importlib.util.spec_from_file_location('runtime_kit',SCRIPT)
kit=importlib.util.module_from_spec(spec);spec.loader.exec_module(kit)

class RuntimeKitTests(unittest.TestCase):
    def test_tampered_missing_extra_and_escaping_inputs_are_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp); contents=root/'Contents'; contents.mkdir()
            binary=contents/'runtime';binary.write_bytes(b'pinned fixture')
            files,links=kit.inventory(contents)
            manifest=root/'kit.json';manifest.write_text(json.dumps({'files':files,'symlinks':links}))
            lock=root/'pin.json';lock.write_text(json.dumps({'manifest_sha256':kit.digest(manifest)}))
            kit.verify(root,lock)
            binary.write_bytes(b'tampered')
            with self.assertRaises(RuntimeError):kit.verify(root,lock)
            binary.unlink()
            with self.assertRaises(RuntimeError):kit.verify(root,lock)
            binary.write_bytes(b'pinned fixture')
            extra=contents/'extra';extra.write_text('unexpected')
            with self.assertRaises(RuntimeError):kit.verify(root,lock)
            extra.unlink();extra.symlink_to(root/'pin.json')
            with self.assertRaises(RuntimeError):kit.verify(root,lock)

if __name__=='__main__':unittest.main()
