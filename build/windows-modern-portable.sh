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

# 2) Source-mode OpenCode imports @opencode-ai/core at runtime, but upstream
# v1.19.0 classifies it as a devDependency. Promote ONLY that workspace package
# into runtime dependencies in the temporary staging checkout, then install the
# production graph. This avoids shipping TypeScript/Prettier/test tooling while
# preserving the source entrypoint's actual runtime contract.
(
  cd "$WORK_DIR"
  python3 - <<'PY'
import json
from pathlib import Path
p = Path("packages/opencode/package.json")
data = json.loads(p.read_text(encoding="utf-8"))
dev = data.setdefault("devDependencies", {})
core = dev.pop("@opencode-ai/core", None)
if core is None:
    raise SystemExit("@opencode-ai/core missing from opencode devDependencies")
data.setdefault("dependencies", {})["@opencode-ai/core"] = core
p.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY

  bun install \
    --frozen-lockfile \
    --production \
    --filter './packages/opencode' \
    --os=win32 \
    --cpu=x64 \
    --backend=copyfile \
    --linker=hoisted \
    --ignore-scripts \
    --no-progress
)

CORE_PKG=""
for candidate in \
  "$WORK_DIR/packages/opencode/node_modules/@opencode-ai/core/package.json" \
  "$WORK_DIR/node_modules/@opencode-ai/core/package.json"; do
  if [[ -e "$candidate" ]]; then
    CORE_PKG="$candidate"
    break
  fi
done
if [[ -z "$CORE_PKG" ]]; then
  CORE_PKG="$(find -L "$WORK_DIR" -path '*/node_modules/@opencode-ai/core/package.json' -print -quit 2>/dev/null || true)"
fi
if [[ -z "$CORE_PKG" ]]; then
  echo "source runtime dependency @opencode-ai/core was not installed" >&2
  exit 1
fi
echo "[ok] core runtime dependency: $CORE_PKG"

# Guard against the dev-tool bloat that made the previous archive ~200 MB.
for unwanted in typescript prettier @typescript/native-preview; do
  if find "$WORK_DIR" -path "*/node_modules/$unwanted/package.json" -print -quit 2>/dev/null | grep -q .; then
    echo "unexpected dev dependency in production graph: $unwanted" >&2
    exit 1
  fi
done

# 3) Materialize workspace links so extraction on Windows does not require
# Developer Mode / symlink privileges. Handle both package-directory links and
# .bin file links.
WORK_ABS="$(cd "$WORK_DIR" && pwd -P)"
materialized_dirs=0
materialized_files=0
while IFS= read -r -d '' link; do
  target="$(readlink -f "$link" 2>/dev/null || true)"
  case "$target" in
    "$WORK_ABS"/packages/*)
      if [[ -d "$target" ]]; then
        tmp_copy="${link}.portable-copy"
        rm -rf "$tmp_copy"
        mkdir -p "$tmp_copy"
        cp -a "$target"/. "$tmp_copy"/
        rm -rf "$tmp_copy/node_modules"
        rm -f "$link"
        mv "$tmp_copy" "$link"
        materialized_dirs=$((materialized_dirs + 1))
      elif [[ -f "$target" ]]; then
        rm -f "$link"
        cp -a "$target" "$link"
        materialized_files=$((materialized_files + 1))
      else
        echo "unsupported workspace symlink target: $link -> $target" >&2
        exit 1
      fi
      ;;
  esac
done < <(find "$WORK_DIR" -type l -path '*/node_modules/*' -print0)
echo "[ok] materialized workspace links: dirs=$materialized_dirs files=$materialized_files"

CORE_VERSION_FILE="$(find "$WORK_DIR" -path '*/node_modules/@opencode-ai/core/src/installation/version.ts' -print -quit 2>/dev/null || true)"
if [[ -z "$CORE_VERSION_FILE" ]]; then
  echo "materialized core workspace is incomplete" >&2
  exit 1
fi

# 4) Bundle the exact Bun version expected by OpenCode v1.19.x.
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

# 5) Strict launcher: a portable runtime must never auto-install missing imports.
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
sed -i 's/$/\r/' "$WORK_DIR/opencode.bat"

# 6) Prune the source checkout aggressively. Runtime resolution only needs:
# - packages/opencode (entrypoint + its assets/tsconfig/package.json)
# - node_modules (installed graph, including materialized workspace packages)
# - runtime/bun + launcher
find "$WORK_DIR/packages" -mindepth 1 -maxdepth 1 ! -name opencode -exec rm -rf {} +
find "$WORK_DIR" -mindepth 1 -maxdepth 1 \
  ! -name packages \
  ! -name node_modules \
  ! -name runtime \
  ! -name opencode.bat \
  -exec rm -rf {} +

# 7) Build-time assertions + size diagnostics.
grep -q -- '--no-install' "$WORK_DIR/opencode.bat"
test -f "$WORK_DIR/runtime/bun/bun.exe"
test -f "$WORK_DIR/packages/opencode/src/index.ts"
test -n "$(find "$WORK_DIR" -path '*/node_modules/@opencode-ai/core/src/installation/version.ts' -print -quit)"

echo "[size] portable staging tree:"
du -sh "$WORK_DIR"
echo "[size] largest top-level runtime entries:"
du -sh "$WORK_DIR"/* 2>/dev/null | sort -h | tail -20

rm -f "$DIST_DIR/$OUT"
tar -czf "$DIST_DIR/$OUT" -C "$ROOT_DIR/tmp" windows-modern
ls -lh "$DIST_DIR/$OUT"
sha256sum "$DIST_DIR/$OUT"
echo "built: $DIST_DIR/$OUT"