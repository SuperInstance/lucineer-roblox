#!/usr/bin/env bash
# ============================================================
# Lucineer Roblox — Build Script (Rojo 7.7.0)
# ============================================================
# Builds the .rbxlx place file from src/ using Rojo.
#
# OUTPUT: ../vibe-world/lucineer-built.rbxlx
#
# Rojo 7.x has a known issue: if $path traverses directories that
# share names with Roblox Instance types (ServerScriptService, etc.),
# Rojo auto-mounts them as Instances instead of following the path.
# This script works around it by copying source to a flat structure.
#
# PREREQUISITES:
#   Rojo 7.7+ installed at ~/.local/bin/rojo or in PATH
#   Install: curl -sL https://github.com/rojo-rbx/rojo/releases/download/v7.7.0/rojo-7.7.0-linux-x86_64.zip -o /tmp/rojo.zip && unzip /tmp/rojo.zip -d ~/.local/bin/
# ============================================================

set -e

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="/tmp/lucineer-rojo-build"
OUTPUT="${SRC_DIR}/../vibe-world/lucineer-built.rbxlx"

# Find rojo
ROJO=$(which rojo 2>/dev/null || echo "$HOME/.local/bin/rojo")
if [ ! -x "$ROJO" ]; then
    echo "ERROR: Rojo not found. Install with:"
    echo "  curl -sL https://github.com/rojo-rbx/rojo/releases/download/v7.7.0/rojo-7.7.0-linux-x86_64.zip -o /tmp/rojo.zip"
    echo "  unzip /tmp/rojo.zip -d ~/.local/bin/"
    exit 1
fi

echo "=== Lucineer Build ==="
echo "Rojo: $($ROJO --version)"
echo "Source: $SRC_DIR/src"

# Prepare flat build directory
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/src/modules"

# Copy all Lua files flat
find "$SRC_DIR/src" -name "*.lua" | while read f; do
    flat=$(echo "$f" | sed "s|$SRC_DIR/src/||; s|/|_|g")
    cp "$f" "$BUILD_DIR/src/modules/$flat"
done

# Copy the project file
cp "$SRC_DIR/build.project.json" "$BUILD_DIR/default.project.json"

# Build
echo "Building..."
cd "$BUILD_DIR"
"$ROJO" build -o "$OUTPUT"
echo "=== Built: $OUTPUT ($(du -h "$OUTPUT" | cut -f1)) ==="
