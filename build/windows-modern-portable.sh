#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "usage: $0 <opencode-tag>" >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
WORK_PARENT="$ROOT_DIR/tmp"
WORK_DIR="$WORK_PARENT/windows-modern"
OUT="opencode-${VERSION}-portable-windows-modern-x64.tar.gz"
UPSTREAM_ZIP_URL="https://github.com/anomalyco/opencode/releases/download/${VERSION}/opencode-windows-x64.zip"

cleanup() {
  rm -rf "$WORK_DIR" "$WORK_PARENT/windows-official"
}
trap cleanup EXIT

rm -rf "$WORK_DIR" "$WORK_PARENT/windows-official"
mkdir -p \
  "$WORK_DIR/bin" \
  "$WORK_DIR/portable-data/config" \
  "$WORK_DIR/portable-data/data" \
  "$WORK_DIR/portable-data/cache" \
  "$WORK_DIR/portable-data/state" \
  "$WORK_DIR/portable-data/tmp" \
  "$WORK_PARENT/windows-official" \
  "$DIST_DIR"

fetch() {
  local url="$1"
  local out="$2"
  echo "[download] $url"
  wget -q --show-progress --tries=3 "$url" -O "$out"
}

# Use the exact upstream compiled Windows CLI for this OpenCode tag. The
# official binary already contains Bun, OpenTUI's Solid transform, embedded
# workers, build-time version/channel constants, and the platform-specific
# native dependencies. Running the raw TypeScript source is NOT equivalent to
# the official build and can leave the interactive TUI blank on Windows.
fetch "$UPSTREAM_ZIP_URL" "$WORK_PARENT/windows-official/opencode.zip"
unzip -q "$WORK_PARENT/windows-official/opencode.zip" -d "$WORK_PARENT/windows-official/extracted"

OFFICIAL_EXE="$(find "$WORK_PARENT/windows-official/extracted" -type f -iname 'opencode.exe' -print -quit)"
if [[ -z "$OFFICIAL_EXE" || ! -f "$OFFICIAL_EXE" ]]; then
  echo "official archive did not contain opencode.exe" >&2
  exit 1
fi
cp "$OFFICIAL_EXE" "$WORK_DIR/bin/opencode.exe"
if [[ ! -s "$WORK_DIR/bin/opencode.exe" ]]; then
  echo "copied opencode.exe is empty" >&2
  exit 1
fi

# Keep the executable below bin/ so adding the portable root to PATH resolves
# `opencode` to opencode.bat instead of bypassing the portable environment via
# PATHEXT's .EXE-before-.BAT ordering.
cat > "$WORK_DIR/opencode.bat" <<'BAT'
@echo off
setlocal EnableExtensions
cd /d "%~dp0"

set "ROOT=%~dp0"
set "PORTABLE=%ROOT%portable-data"

if not exist "%PORTABLE%\config" mkdir "%PORTABLE%\config"
if not exist "%PORTABLE%\data" mkdir "%PORTABLE%\data"
if not exist "%PORTABLE%\cache" mkdir "%PORTABLE%\cache"
if not exist "%PORTABLE%\state" mkdir "%PORTABLE%\state"
if not exist "%PORTABLE%\tmp" mkdir "%PORTABLE%\tmp"

rem Keep OpenCode's persistent state beside this launcher.
set "OPENCODE_CONFIG_DIR=%PORTABLE%\config"
set "OPENCODE_DB=%PORTABLE%\data\opencode.db"
set "XDG_CONFIG_HOME=%PORTABLE%\config"
set "XDG_DATA_HOME=%PORTABLE%\data"
set "XDG_CACHE_HOME=%PORTABLE%\cache"
set "XDG_STATE_HOME=%PORTABLE%\state"

rem Releases are controlled by this portable repository, not by self-update.
set "OPENCODE_DISABLE_AUTOUPDATE=1"

"%ROOT%bin\opencode.exe" %*
exit /b %ERRORLEVEL%
BAT
sed -i 's/$/\r/' "$WORK_DIR/opencode.bat"

# Build assertions that are valid on the Linux Actions builder. Runtime/version
# verification happens later on windows-latest before any release is allowed.
test -s "$WORK_DIR/bin/opencode.exe"
grep -q -- 'OPENCODE_CONFIG_DIR=' "$WORK_DIR/opencode.bat"
grep -q -- 'OPENCODE_DB=' "$WORK_DIR/opencode.bat"
grep -q -- 'XDG_DATA_HOME=' "$WORK_DIR/opencode.bat"
grep -q -- 'XDG_CACHE_HOME=' "$WORK_DIR/opencode.bat"
grep -q -- 'XDG_STATE_HOME=' "$WORK_DIR/opencode.bat"
grep -q -- 'OPENCODE_DISABLE_AUTOUPDATE=1' "$WORK_DIR/opencode.bat"

# Preserve empty portable directories in archives/tools that may drop empties.
for dir in config data cache state tmp; do
  printf 'portable runtime directory\n' > "$WORK_DIR/portable-data/$dir/.keep"
done

echo "[ok] staged official Windows CLI for $VERSION"
echo "[size] staging tree:"
du -sh "$WORK_DIR"
du -sh "$WORK_DIR"/* 2>/dev/null | sort -h

rm -f "$DIST_DIR/$OUT"
tar -czf "$DIST_DIR/$OUT" -C "$WORK_PARENT" windows-modern
ls -lh "$DIST_DIR/$OUT"
sha256sum "$DIST_DIR/$OUT"
echo "built: $DIST_DIR/$OUT"
