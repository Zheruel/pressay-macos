#!/usr/bin/env python3
"""Reject bundled Mach-O files requiring a newer macOS than the app advertises."""
from pathlib import Path
import argparse
import json
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent
MAGIC = {b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xfe\xed\xfa\xce", b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"}

def declared_minimum():
    return json.loads((ROOT / "apps/desktop/src-tauri/tauri.conf.json").read_text())["bundle"]["macOS"]["minimumSystemVersion"]

def version(value):
    if not re.fullmatch(r"\d+(?:\.\d+){0,2}", value):
        raise ValueError(f"Invalid macOS version: {value}")
    return tuple(int(part) for part in value.split(".")) + (0,) * (3 - len(value.split(".")))

def verify(paths, minimum):
    maximum = version(minimum)
    checked = 0
    failures = []
    for root in paths:
        if not root.exists():
            raise ValueError(f"Missing build artifact: {root}")
        for path in sorted(root.rglob("*") if root.is_dir() else [root]):
            if not path.is_file() or path.is_symlink():
                continue
            with path.open("rb") as handle:
                if handle.read(4) not in MAGIC:
                    continue
            result = subprocess.check_output(["xcrun", "vtool", "-show-build", str(path)], text=True)
            # LC_BUILD_VERSION uses minos; older LC_VERSION_MIN_MACOSX uses version.
            found = []
            for command in re.split(r"Load command \d+", result):
                field = "minos" if "cmd LC_BUILD_VERSION" in command else "version" if "cmd LC_VERSION_MIN_MACOSX" in command else None
                if field:
                    found.extend(re.findall(rf"^\s*{field}\s+(\d+(?:\.\d+){{0,2}})\s*$", command, re.MULTILINE))
            if not found:
                failures.append(f"{path}: missing deployment metadata")
            elif any(version(value) > maximum for value in found):
                failures.append(f"{path}: requires macOS {', '.join(found)}, advertised {minimum}")
            checked += 1
    if failures:
        raise ValueError("Incompatible macOS deployment targets:\n" + "\n".join(failures))
    if not checked:
        raise ValueError("No Mach-O build artifacts were checked")
    print(f"Verified {checked} Mach-O artifacts require macOS {minimum} or earlier.")
    return checked

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="+", type=Path)
    parser.add_argument("--minimum", default=declared_minimum())
    args = parser.parse_args()
    try:
        verify(args.paths, args.minimum)
    except (ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, str(error) + "\n")

if __name__ == "__main__":
    main()
