#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "usage: $0 <opencode-tag>" >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
WORK_DIR="$ROOT_DIR/tmp/windows-modern"
ENTRYPOINT="packages/opencode/src/index.ts"
BUN_TAG="bun-v1.3.14"
BUN_URL="https://github.com/oven-sh/bun/releases/download/${BUN_TAG}/bun-windows-x64.zip"
SOURCE_URL="https://github.com/anomalyco/opencode/archive/refs/tags/${VERSION}.tar.gz"
OUT="opencode-${VERSION}-portable-windows-modern-x64.tar.gz"

cleanup() {
  rm -rf "$ROOT_DIR/tmp/windows-modern"
}
trap cleanup EXIT

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR/runtime/bun" "$DIST_DIR"

fetch() {
  local url="$1"
  local out="$2"
  echo "[download] $url"
  wget -q --show-progress --tries=3 "$url" -O "$out"
}

# 1) Fetch the exact upstream source tag.
fetch "$SOURCE_URL" "$WORK_DIR/source.tar.gz"
tar -xzf "$WORK_DIR/source.tar.gz" --strip-components=1 -C "$WORK_DIR"
rm -f "$WORK_DIR/source.tar.gz"

if [[ ! -f "$WORK_DIR/$ENTRYPOINT" ]]; then
  echo "missing entrypoint: $ENTRYPOINT" >&2
  exit 1
fi

if ! command -v bun >/dev/null 2>&1; then
  echo "CI build requires Bun 1.3.14" >&2
  exit 1
fi

if [[ "$(bun --version)" != "1.3.14" ]]; then
  echo "expected build Bun 1.3.14, got $(bun --version)" >&2
  exit 1
fi

# 2) Resolve the complete production workspace graph for Windows x64 at build time.
# Runtime is deliberately forbidden from auto-installing missing imports.
(
  cd "$WORK_DIR"
  bun install \
    --frozen-lockfile \
    --production \
    --filter '{./packages/opencode}...' \
    --os=win32 \
    --cpu=x64 \
    --backend=copyfile \
    --linker=hoisted \
    --ignore-scripts
)

if [[ ! -e "$WORK_DIR/node_modules/@opencode-ai/core/package.json" ]]; then
  echo "workspace dependency @opencode-ai/core was not installed" >&2
  exit 1
fi

# 3) Bun may link workspace:* packages back into packages/. Those links are not
# portable across extraction, so materialize only links that resolve inside this
# source tree. Leave ordinary npm package links untouched.
WORK_ABS="$(cd "$WORK_DIR" && pwd -P)"
while IFS= read -r -d '' link; do
  target="$(readlink -f "$link" 2>/dev/null || true)"
  case "$target" in
    "$WORK_ABS"/packages/*)
      tmp_copy="${link}.portable-copy"
      rm -rf "$tmp_copy"
      mkdir -p "$tmp_copy"
      cp -a "$target"/. "$tmp_copy"/
      rm -rf "$tmp_copy/node_modules"
      rm -f "$link"
      mv "$tmp_copy" "$link"
      ;;
  esac
done < <(find "$WORK_DIR/node_modules" -type l -print0)

if [[ -L "$WORK_DIR/node_modules/@opencode-ai/core" ]]; then
  echo "workspace materialization failed for @opencode-ai/core" >&2
  exit 1
fi

# 4) Bundle the same Bun version OpenCode v1.19.x expects.
fetch "$BUN_URL" "$WORK_DIR/bun.zip"
unzip -q "$WORK_DIR/bun.zip" -d "$WORK_DIR/runtime/bun"
rm -f "$WORK_DIR/bun.zip"

if [[ ! -f "$WORK_DIR/runtime/bun/bun.exe" ]]; then
  bun_exe="$(find "$WORK_DIR/runtime/bun" -type f -name bun.exe -print -quit)"
  if [[ -z "$bun_exe" ]]; then
    echo "bun.exe not found after unzip" >&2
    exit 1
  fi
  mv "$bun_exe" "$WORK_DIR/runtime/bun/bun.exe"
fi

# 5) Strict launcher: no hidden runtime dependency installation.
cat > "$WORK_DIR/opencode.bat" <<'BAT'
@echo off
setlocal EnableExtensions
cd /d "%~dp0"
set "OPENCODE_ENTRYPOINT=packages\opencode\src\index.ts"
if not exist "runtime\bun\bun.exe" (
  echo [ERROR] Bun runtime not found!
  exit /b 1
)
for /f "delims=" %%b in ('"runtime\bun\bun.exe" --version') do echo [INFO] Bun %%b
"runtime\bun\bun.exe" --no-install "%OPENCODE_ENTRYPOINT%" %*
exit /b %ERRORLEVEL%
BAT
# cmd.exe is happiest with CRLF.
sed -i 's/$/\r/' "$WORK_DIR/opencode.bat"

# 6) Build-time assertions for the portable contract.
if ! grep -q -- '--no-install' "$WORK_DIR/opencode.bat"; then
  echo "launcher does not disable Bun auto-install" >&2
  exit 1
fi
if [[ ! -f "$WORK_DIR/node_modules/@opencode-ai/core/src/installation/version.ts" ]]; then
  echo "materialized core workspace is incomplete" >&2
  exit 1
fi

rm -f "$DIST_DIR/$OUT"
tar -czf "$DIST_DIR/$OUT" -C "$ROOT_DIR/tmp" windows-modern
sha256sum "$DIST_DIR/$OUT"
echo "built: $DIST_DIR/$OUT"