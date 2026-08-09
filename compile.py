#!/usr/bin/env python3
"""
Lucineer Roblox — Lua syntax checker

Runs lua5.1 syntax checks on all .lua files in src/.
Used as a pre-commit check before building with Rojo.
"""

import subprocess
import sys
from pathlib import Path


def check_lua_files(base_dir: str = "src") -> int:
    """Check all .lua files under base_dir for syntax errors."""
    base = Path(base_dir)
    if not base.exists():
        print(f"Source directory '{base_dir}' not found")
        return 1

    lua_files = list(base.rglob("*.lua"))
    if not lua_files:
        print(f"No .lua files found in {base_dir}/")
        return 0

    errors = 0
    for f in sorted(lua_files):
        result = subprocess.run(
            ["lua5.1", "-e", f"assert(loadfile('{f}'))"],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            print(f"✗ {f}: {result.stderr.strip()}")
            errors += 1
        else:
            print(f"✓ {f}")

    total = len(lua_files)
    print(f"\n{total - errors}/{total} files OK")
    return 0 if errors == 0 else 1


if __name__ == "__main__":
    sys.exit(check_lua_files())
