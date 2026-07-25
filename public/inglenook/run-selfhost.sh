#!/bin/sh
# run-selfhost.sh — build + launch Inglenook compiled by the SELF-HOSTED C-emit backend
# (selfhost/cgen_c.ig), the counterpart to run.sh (which uses the stage-0 backend). Same runtime,
# same app, same pixels — only the COMPILER that produced the binary differs. macOS: raylib +
# libcurl via pkg-config/curl-config, Cocoa frameworks.
#
# Usage: ANTHROPIC_API_KEY=sk-ant-... ./public/inglenook/run-selfhost.sh
#        (runs without a key too — pick Ollama in Settings, or sending just reminds you)
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

# 1. Stage-0 compiler (build/inglec) + the net+graphics runtime objects (runtime/cextern/graphics built
#    -DEMBER_NET -DEMBER_GRAPHICS -DEMBER_PARALLEL). `make net-graphics` builds both.
make net-graphics >/dev/null

# 2. Compile the SELF-HOSTED C-emit driver (the compiler's own backend) to a native binary.
build/inglec --emit=c selfhost/cgen_c_dump.ig > build/cgc-self.c
clang -std=c17 -Iinclude -O2 build/cgc-self.c src/runtime.c src/cextern.c -lm -o build/cgc-self

# 3. Emit Inglenook's C THROUGH the self-hosted backend (strip the driver's own `=> 0` main-return line).
EMBER_STD="$ROOT/std" build/cgc-self public/inglenook/ide.ig | sed -e '/^=> 0$/d' > build/inglenook-self.c

# 4. Link it against the net+graphics runtime + raylib/libcurl/Cocoa → a standalone GUI binary.
clang -std=c17 -Iinclude -O2 -DEMBER_NET=1 -DEMBER_GRAPHICS=1 -DEMBER_PARALLEL=1 \
  $(curl-config --cflags) $(pkg-config --cflags raylib freetype2) \
  build/inglenook-self.c \
  build/runtime_rt_netgfx.o build/cextern_rt_netgfx.o build/graphics_rt_netgfx.o \
  $(pkg-config --libs raylib freetype2) $(curl-config --libs) \
  -framework Cocoa -framework IOKit -framework CoreVideo -framework OpenGL \
  -lm -pthread -o build/inglenook-self

# The Verified Loop / linter / tape-scrubber shell out to a compiler; the Source panel to `quog`.
: "${INGLENOOK_INGLEC:=$ROOT/build/inglec}"; export INGLENOOK_INGLEC
: "${EMBER_TAPE:=/tmp/inglenook.tape}"; export EMBER_TAPE
make quog >/dev/null 2>&1 || true
if [ -x "$ROOT/build/quog" ]; then : "${INGLENOOK_QUOG:=$ROOT/build/quog}"; export INGLENOOK_QUOG; fi

echo "Inglenook (self-hosted build) — UI tape -> $EMBER_TAPE" >&2
exec build/inglenook-self
