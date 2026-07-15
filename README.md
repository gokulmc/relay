# Relay

A native macOS menu-bar app that toggles Claude Code (CLI + VS Code extension)
between your claude.ai subscription and DeepSeek API credits, routed through a
locally-run LiteLLM proxy.

- **Single ON/OFF toggle** — "Switch to DeepSeek" / "Switch to Claude".
  Flipping it does not touch your saved claude.ai login.
- **Own isolated Python environment** for LiteLLM
  (`~/Library/Application Support/Relay/venv`).
- Manages both Claude Code config surfaces: `~/.claude/settings.json` (CLI) and
  VS Code's `claudeCode.environmentVariables`.

## Requirements

- macOS 13+
- A usable `python3` ≥ 3.9 with `ensurepip` (Homebrew or python.org; not the
  bare Xcode CLT stub)
- A DeepSeek API key

## Build & install

```bash
# One-time: stable local signing identity (optional but recommended)
./setup-signing.sh

# Optional icon
swift scripts/render-icon.swift

# Install to /Applications and launch
./build.sh

# Or assemble Relay.app in-repo only (no /Applications write)
SKIP_INSTALL=1 ./build.sh
open ./Relay.app
```

`build.sh` builds a release binary, assembles `Relay.app`, and codesigns it.
Without `SKIP_INSTALL=1` it also installs to `/Applications` and launches.

## Use

1. Open Relay from the menu bar (arrow.triangle.2.circlepath icon).
2. **DeepSeek Settings…** — paste your API key and confirm the model string
   (default `deepseek/deepseek-v4-pro`).
3. **Switch to DeepSeek** — installs the venv on first use, writes settings,
   starts LiteLLM on port 4000.
4. **Restart** any open `claude` terminals and VS Code windows.
5. **Switch to Claude** to restore subscription routing (no re-login).

## Develop

```bash
swift test
swift build
```

See `docs/SPEC.md` and `docs/IMPLEMENTATION.md`.

## Status

Core RelayKit + AppKit menu UI implemented. Manual E2E (real DeepSeek calls,
VS Code extension check) still depends on your API key and local Claude Code
install.
