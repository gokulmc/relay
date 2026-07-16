# Relay — Specification

Relay is a macOS menu-bar app that routes Claude Code (CLI + VS Code extension)
through a local LiteLLM proxy to DeepSeek, without disturbing the saved
claude.ai subscription login.

## What it does

- **Toggle routing** between Claude (claude.ai subscription) and DeepSeek (via
  local LiteLLM on `http://127.0.0.1:4000`).
- **Writes two config surfaces**:
  - CLI: `env.ANTHROPIC_BASE_URL` / `env.ANTHROPIC_AUTH_TOKEN` in
    `~/.claude/settings.json` (full JSON merge).
  - VS Code: `claudeCode.environmentVariables` in
    `~/Library/Application Support/Code/User/settings.json` (textual patch so
    JSONC comments survive).
- **Manages an isolated Python venv** at
  `~/Library/Application Support/Relay/venv` with `litellm[proxy]`.
- **Stores secrets in Keychain**: DeepSeek API key + generated LiteLLM master
  key (`com.gokul.relay.*` service names).
- **Proxy lifecycle** tied to the app process (start on DeepSeek toggle / manual
  start; stop on Claude toggle / Quit). No launchd daemon in v1.

## Non-goals / caveats

- Anthropic does not endorse third-party gateways for routing Claude Code to
  non-Claude models. This is a personal tooling pattern; LiteLLM documents it.
- Already-open `claude` terminals and VS Code windows must be restarted after a
  toggle — settings are read at process start.
- Bundle id `com.gokul.relay` is a placeholder convention matching other local
  tools; rename before treating signing identity as permanent if desired.

## UI

AppKit `NSStatusItem` + `NSMenu` (MemBar-style header + stock menu items):

- Header: mode hero (Claude / DeepSeek), subline, proxy status pill
- Switch to DeepSeek / Switch to Claude
- Start Proxy / Stop Proxy
- DeepSeek Settings… (API key + model string)
- View Proxy Logs
- Repair / Reinstall LiteLLM Environment
- Quit
