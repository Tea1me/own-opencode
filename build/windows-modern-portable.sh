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
  "$WORK_DIR/portable-data/config/opencode" \
  "$WORK_DIR/portable-data/data/opencode" \
  "$WORK_DIR/portable-data/cache" \
  "$WORK_DIR/portable-data/state" \
  "$WORK_DIR/portable-data/tmp" \
  "$WORK_DIR/portable-data/home/AppData/Roaming" \
  "$WORK_DIR/portable-data/home/AppData/Local" \
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
# native dependencies.
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

# Canonical package-local global config. OpenCode v1.19 writes global config
# through Global.Path.config (= XDG_CONFIG_HOME/opencode), so keep
# OPENCODE_CONFIG_DIR and XDG_CONFIG_HOME aligned to this exact directory.
cat > "$WORK_DIR/portable-data/config/opencode/opencode.jsonc" <<'JSONC'
{
  "$schema": "https://opencode.ai/config.json"
}
JSONC

# Keep the executable below bin/ so adding the portable root to PATH resolves
# `opencode` to opencode.bat. The launcher NEVER changes cwd: invoking it from a
# project directory must keep that project as OpenCode's working directory.
cat > "$WORK_DIR/opencode.bat" <<'BAT'
@echo off
setlocal EnableExtensions

set "ROOT=%~dp0"
set "PORTABLE=%ROOT%portable-data"
set "PORTABLE_HOME=%PORTABLE%\home"
set "CONFIG_HOME=%PORTABLE%\config"
set "CONFIG_DIR=%CONFIG_HOME%\opencode"
set "DATA_HOME=%PORTABLE%\data"
set "CACHE_HOME=%PORTABLE%\cache"
set "STATE_HOME=%PORTABLE%\state"
set "TMP_HOME=%PORTABLE%\tmp"

if not exist "%CONFIG_DIR%" mkdir "%CONFIG_DIR%"
if not exist "%DATA_HOME%\opencode" mkdir "%DATA_HOME%\opencode"
if not exist "%CACHE_HOME%" mkdir "%CACHE_HOME%"
if not exist "%STATE_HOME%" mkdir "%STATE_HOME%"
if not exist "%TMP_HOME%" mkdir "%TMP_HOME%"
if not exist "%PORTABLE_HOME%\AppData\Roaming" mkdir "%PORTABLE_HOME%\AppData\Roaming"
if not exist "%PORTABLE_HOME%\AppData\Local" mkdir "%PORTABLE_HOME%\AppData\Local"
if not exist "%CONFIG_DIR%\opencode.jsonc" (
  >"%CONFIG_DIR%\opencode.jsonc" echo {
  >>"%CONFIG_DIR%\opencode.jsonc" echo   "$schema": "https://opencode.ai/config.json"
  >>"%CONFIG_DIR%\opencode.jsonc" echo }
)

rem Strict portable home. This prevents libraries that ignore XDG variables
rem from falling back to C:\Users\<user> for OpenCode-owned state.
set "HOME=%PORTABLE_HOME%"
set "USERPROFILE=%PORTABLE_HOME%"
set "APPDATA=%PORTABLE_HOME%\AppData\Roaming"
set "LOCALAPPDATA=%PORTABLE_HOME%\AppData\Local"

rem OpenCode/XDG paths. CONFIG_DIR intentionally equals XDG_CONFIG_HOME\opencode
rem because v1.19 global config writes use Global.Path.config directly.
set "XDG_CONFIG_HOME=%CONFIG_HOME%"
set "XDG_DATA_HOME=%DATA_HOME%"
set "XDG_CACHE_HOME=%CACHE_HOME%"
set "XDG_STATE_HOME=%STATE_HOME%"
set "XDG_RUNTIME_DIR=%TMP_HOME%"
set "OPENCODE_CONFIG_DIR=%CONFIG_DIR%"
set "OPENCODE_DB=%DATA_HOME%\opencode\opencode.db"

rem Temporary files stay beside the application too.
set "TEMP=%TMP_HOME%"
set "TMP=%TMP_HOME%"

rem Releases are controlled by this portable repository, not by self-update.
set "OPENCODE_DISABLE_AUTOUPDATE=1"

"%ROOT%bin\opencode.exe" %*
exit /b %ERRORLEVEL%
BAT
sed -i 's/$/\r/' "$WORK_DIR/opencode.bat"

# Build assertions valid on the Linux Actions builder. Runtime verification is
# performed on windows-latest before any release is allowed.
test -s "$WORK_DIR/bin/opencode.exe"
test -f "$WORK_DIR/portable-data/config/opencode/opencode.jsonc"
! grep -qi -- '^cd /d ' "$WORK_DIR/opencode.bat"
grep -q -- 'HOME=%PORTABLE_HOME%' "$WORK_DIR/opencode.bat"
grep -q -- 'USERPROFILE=%PORTABLE_HOME%' "$WORK_DIR/opencode.bat"
grep -q -- 'APPDATA=%PORTABLE_HOME%' "$WORK_DIR/opencode.bat"
grep -q -- 'LOCALAPPDATA=%PORTABLE_HOME%' "$WORK_DIR/opencode.bat"
grep -q -- 'OPENCODE_CONFIG_DIR=%CONFIG_DIR%' "$WORK_DIR/opencode.bat"
grep -q -- 'OPENCODE_DB=%DATA_HOME%\\opencode\\opencode.db' "$WORK_DIR/opencode.bat"
grep -q -- 'XDG_CONFIG_HOME=%CONFIG_HOME%' "$WORK_DIR/opencode.bat"
grep -q -- 'XDG_DATA_HOME=%DATA_HOME%' "$WORK_DIR/opencode.bat"
grep -q -- 'XDG_CACHE_HOME=%CACHE_HOME%' "$WORK_DIR/opencode.bat"
grep -q -- 'XDG_STATE_HOME=%STATE_HOME%' "$WORK_DIR/opencode.bat"
grep -q -- 'XDG_RUNTIME_DIR=%TMP_HOME%' "$WORK_DIR/opencode.bat"
grep -q -- 'TEMP=%TMP_HOME%' "$WORK_DIR/opencode.bat"
grep -q -- 'TMP=%TMP_HOME%' "$WORK_DIR/opencode.bat"
grep -q -- 'OPENCODE_DISABLE_AUTOUPDATE=1' "$WORK_DIR/opencode.bat"

# Preserve otherwise-empty runtime directories in archives/tools that drop them.
for dir in cache state tmp; do
  printf 'portable runtime directory\n' > "$WORK_DIR/portable-data/$dir/.keep"
done
printf 'portable runtime directory\n' > "$WORK_DIR/portable-data/data/opencode/.keep"
printf 'portable runtime directory\n' > "$WORK_DIR/portable-data/home/.keep"

echo "[ok] staged strict Windows portable for $VERSION"
echo "[size] staging tree:"
du -sh "$WORK_DIR"
du -sh "$WORK_DIR"/* 2>/dev/null | sort -h

rm -f "$DIST_DIR/$OUT"
tar -czf "$DIST_DIR/$OUT" -C "$WORK_PARENT" windows-modern
ls -lh "$DIST_DIR/$OUT"
sha256sum "$DIST_DIR/$OUT"
echo "built: $DIST_DIR/$OUT"
