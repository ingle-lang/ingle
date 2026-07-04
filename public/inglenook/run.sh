#!/bin/sh
# Build the net+graphics compiler (libcurl + raylib) and run Inglenook from the repo root.
# Usage: ANTHROPIC_API_KEY=sk-ant-... ./public/inglenook/run.sh
#        (runs without a key too — pick Ollama in Settings, or sending just reminds you)
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
make net-graphics >/dev/null
exec build/inglec-net-gfx --emit=run public/inglenook/ide.ig
