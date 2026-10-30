#!/usr/bin/env python3
"""Check publication candidates without printing file contents or secret values."""
import argparse
import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SKIP_DIRS = {".git", ".dart_tool", "build", ".gradle", ".idea", "Pods", "ephemeral",
             "node_modules", ".venv", "__pycache__", ".pytest_cache", "backups", "design_refs", "artifacts"}
TEXT_SUFFIXES = {".dart", ".py", ".json", ".yaml", ".yml", ".md", ".toml", ".txt",
                 ".properties", ".xml", ".sh", ".mjs", ".js", ".env", ".example",
                 ".kt", ".kts", ".gradle", ".java", ".swift", ".m", ".mm", ".h",
                 ".c", ".cpp", ".plist", ".entitlements", ".xcconfig", ".pbxproj", ".lock"}
KEY_PATTERN = re.compile(rb"gsk_[A-Za-z0-9_-]{20,}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----")


def private_path(path: str) -> bool:
    p = Path(path)
    name = p.name.lower()
    if name == ".env.example":
        return False
    return (name == ".env" or name.startswith(".env.") or name.endswith(".env") or ".env." in name or
            name in {"google-services.json", "googleservice-info.plist", "firebase_options.dart",
                     "credentials.json", "application_default_credentials.json", "local.properties", "key.properties"} or
            any(word in name for word in ("service-account", "service_account", "firebase-adminsdk")) or
            p.suffix.lower() in {".pem", ".key", ".jks", ".keystore", ".p12", ".pfx", ".p8", ".mobileprovision"} or
            any(part in {"secrets", ".secrets", "backups", "design_refs", "artifacts"} for part in p.parts))


def unsafe_content(raw: bytes) -> bool:
    if KEY_PATTERN.search(raw):
        return True
    try:
        data = json.loads(raw)
    except (ValueError, UnicodeDecodeError):
        return False
    return isinstance(data, dict) and (data.get("type") == "service_account" or "private_key" in data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--staged", action="store_true", help="Check Git's exact staged contents, including forced-add secrets")
    args = parser.parse_args()
    failures = []
    if args.staged:
        result = subprocess.run(["git", "diff", "--cached", "--name-only", "--diff-filter=ACMR", "-z"],
                                cwd=ROOT, capture_output=True)
        if result.returncode:
            print("Cannot inspect Git staging area; check failed closed.")
            return 1
        for name in result.stdout.decode().split("\0"):
            if not name:
                continue
            raw = subprocess.run(["git", "show", f":{name}"], cwd=ROOT, capture_output=True, check=True).stdout
            if private_path(name) or unsafe_content(raw):
                failures.append(name)
    else:
        for p in ROOT.rglob("*"):
            relative = p.relative_to(ROOT)
            if (not p.is_file() or any(part in SKIP_DIRS for part in relative.parts)
                    or private_path(str(relative)) or p.suffix not in TEXT_SUFFIXES):
                continue
            if unsafe_content(p.read_bytes()):
                failures.append(str(relative))
    if failures:
        print("Publication check failed. Review these paths privately:")
        for name in failures:
            print(name)
        return 1
    print("Publication content check passed; no matching provider/private-key literals found.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
