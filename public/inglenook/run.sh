#!/bin/sh
# Build the net+graphics compiler (libcurl + raylib) and run Inglenook from the repo root.
# Usage: ANTHROPIC_API_KEY=sk-ant-... ./public/inglenook/run.sh
#        (runs without a key too — pick Ollama in Settings, or sending just reminds you)
#
# Diagnostics: the UI TAPE is recorded to $EMBER_TAPE (default /tmp/inglenook.tape) — one JSON line
# per frame (input + every draw command + interaction events). `tail -f /tmp/inglenook.tape` while the
# app runs to watch it live, or read it after to see whether the render thread is alive (frames still
# advancing) vs frozen, and what state it's in. Set EMBER_TAPE= (empty) to turn it off (zero cost).
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
make net-graphics >/dev/null
: "${EMBER_TAPE:=/tmp/inglenook.tape}"
export EMBER_TAPE
# The Verified Loop / linter / tape-scrubber shell out to the compiler; default to the one we just
# built so they work without a separately-installed `inglec` on PATH (override with INGLENOOK_INGLEC=).
: "${INGLENOOK_INGLEC:=$ROOT/build/inglec}"
export INGLENOOK_INGLEC
echo "Inglenook: UI tape → $EMBER_TAPE   (tail -f it to watch; EMBER_TAPE= to disable)" >&2
exec build/inglec-net-gfx --emit=run public/inglenook/ide.ig
