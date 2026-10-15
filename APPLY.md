# opencode-portable Windows source/TS fix

1. In `build/build.sh`, replace the entire existing `build_windows()` function with `build_windows.fixed.sh`.
2. In `.github/workflows/auto-build.yml`, insert `workflow-bun-step.yml` immediately after the existing `安装依赖` step and before `构建`.
3. Commit and run `workflow_dispatch`.
4. On Windows 10, download/test the `windows-modern-x64` artifact first.

This keeps the source + bundled runtime approach. It does NOT use the upstream `opencode.exe`.

Key changes:
- entrypoint: `packages/opencode/src/index.ts`
- preinstall Win32/x64 production dependencies into the portable package
- keep modern Bun runtime
- keep legacy Node 18 runtime, with bundled `tsx` only so Node can execute `.ts`
- force generated `opencode.bat` to CRLF
- `cd /d "%~dp0"` so PATH launches work from any current directory
- normalize Bun zip layout when `bun.exe` is nested
