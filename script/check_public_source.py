#!/usr/bin/env python3
"""Review repository text and paths for common publication leaks; no raw matches."""
import argparse
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
GENERATED_ROOTS = {".git", ".build", ".cache", "dist", "vm", "artifacts", "__pycache__"}
DENIED_PARTS = {".codex", ".agents", ".aws", ".ssh", ".DS_Store", "MobileAstra", "MobileAstraCompat"}
DENIED_SUFFIXES = {".log", ".trace", ".iso", ".raw", ".qcow2", ".vhdx", ".p12", ".pfx", ".pem", ".key", ".cer", ".pyc", ".mobileprovision"}
PATTERNS = {
    "mac_user_path": re.compile(r"/Users/[^/\s\"']+/"),
    "home_user_path": re.compile(r"/home/[^/\s\"']+/"),
    "windows_user_path": re.compile(r"[A-Za-z]:\\Users\\[^\\\s\"']+\\", re.I),
    "private_key": re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    "github_token": re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{30,})\b"),
    "openai_token": re.compile(r"\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{24,}\b"),
    "aws_access_id": re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"),
    "url_credentials": re.compile(r"https?://[^\s/@:]+:[^\s/@]+@"),
    "stored_cookie": re.compile(r"(?:^|\n)\s*(?:Cookie|Set-Cookie)\s*:", re.I),
    "literal_secret": re.compile(r"(?:api[_-]?key|password|passwd|client[_-]?secret|access[_-]?token)\s*[:=]\s*[\"'][^\"'\n]{8,}[\"']", re.I),
}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--all-files", action="store_true", help="Check every file in the export rather than Git tracked files")
    args = parser.parse_args()
    if args.all_files:
        paths = []
        for current, directories, files in __import__("os").walk(ROOT, followlinks=False):
            current = Path(current)
            directories[:] = [name for name in directories if name not in GENERATED_ROOTS
                and current / name not in {ROOT / "vendor/graphics" / component for component in ["dxmt", "virglrenderer", "neptune"]}
                and not name.startswith(".fetch-")]
            paths.extend(current / name for name in files)
            paths.extend(current / name for name in directories if (current / name).is_symlink())
        paths.sort()
    else:
        result = subprocess.run(["git", "ls-files", "-z"], cwd=ROOT, capture_output=True, check=True)
        paths = [ROOT / name.decode() for name in result.stdout.split(b"\0") if name]
        if not paths:
            raise SystemExit("No tracked source. Use --all-files for a prepared export.")
    findings = []
    for path in paths:
        rel = str(path.relative_to(ROOT))
        if DENIED_PARTS.intersection(path.relative_to(ROOT).parts) or path.suffix.lower() in DENIED_SUFFIXES or path.name.startswith((".env", "cookies")):
            findings.append({"path": rel, "category": "excluded_file"})
            continue
        if path.is_symlink():
            if not path.resolve().is_relative_to(ROOT) or not path.resolve().exists():
                findings.append({"path": rel, "category": "escaping_or_broken_link"})
            continue
        data = path.read_bytes()
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            findings.append({"path": rel, "category": "non_text_file"})
            continue
        if b"\0" in data:
            findings.append({"path": rel, "category": "binary_content"})
        # This scanner's regex literals are detectors, not stored credentials.
        if path.resolve() == Path(__file__).resolve():
            continue
        for category, pattern in PATTERNS.items():
            for match in pattern.finditer(text):
                findings.append({"path": rel, "category": category, "line": text[:match.start()].count("\n") + 1})
    print(json.dumps({"result": "FAIL" if findings else "PASS", "files_checked": len(paths), "findings": findings}, indent=2))
    raise SystemExit(1 if findings else 0)

if __name__ == "__main__":
    main()
