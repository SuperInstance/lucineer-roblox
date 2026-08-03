#!/usr/bin/env bash
# ============================================================
# Lucineer Roblox — Build Script
# ============================================================
# Builds the .rbxlx place file from src/ using Rojo.
#
# OUTPUT: ../vibe-world/lucineer-built.rbxlx
#
# PREREQUISITES:
#   Rojo must be installed. Install with:
#     cargo install rojo --version 7.5.1
#   (Rust/Cargo required: https://rustup.rs)
#
#   Or download a prebuilt binary from:
#     https://github.com/rojo-rbx/rojo/releases
#
#   For live-sync during development (requires Rojo Studio plugin):
#     rojo serve default.project.json
#
# USAGE:
#   ./build.sh              # Build to ../vibe-world/lucineer-built.rbxlx
#   ./build.sh /custom/path # Build to custom output path
#   ./build.sh --serve      # Start live sync server (port 34872)
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PROJECT_FILE="default.project.json"
DEFAULT_OUTPUT="../vibe-world/lucineer-built.rbxlx"

# ─── Check for rojo ───────────────────────────────────────────

if ! command -v rojo &>/dev/null; then
    echo "❌ Rojo is not installed."
    echo ""
    echo "Install options:"
    echo "  1. cargo install rojo --version 7.5.1"
    echo "  2. Download from https://github.com/rojo-rbx/rojo/releases"
    echo ""
    echo "Then re-run this script."
    exit 1
fi

ROJO_VERSION=$(rojo --version 2>&1 || echo "unknown")
echo "🔧 Using Rojo: $ROJO_VERSION"

# ─── Handle subcommands ───────────────────────────────────────

if [[ "${1:-}" == "--serve" ]]; then
    echo "🚀 Starting Rojo live-sync server..."
    echo "   Connect from Studio using the Rojo plugin."
    exec rojo serve "$PROJECT_FILE"
fi

# ─── Build ────────────────────────────────────────────────────

OUTPUT_PATH="${1:-$DEFAULT_OUTPUT}"

# Create output directory if it doesn't exist
OUTPUT_DIR="$(dirname "$OUTPUT_PATH")"
mkdir -p "$OUTPUT_DIR"

echo "📦 Building..."
echo "   Project: $PROJECT_FILE"
echo "   Output:  $OUTPUT_PATH"
echo ""

rojo build "$PROJECT_FILE" -o "$OUTPUT_PATH"

echo ""
echo "✅ Build complete: $OUTPUT_PATH"
echo ""
echo "To use in Roblox Studio:"
echo "  1. Open the .rbxlx file in Studio"
echo "  2. Or use 'rojo serve' for live-sync development"
