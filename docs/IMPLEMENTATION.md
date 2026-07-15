# Relay — Implementation log

## M1 — Scaffold

- `Package.swift`: `RelayKit` + `RelayApp` + `RelayKitTests` (no CLI target).
- `build.sh` / `setup-signing.sh` / `Support/Info.plist` (`LSUIElement`,
  bundle id `com.gokul.relay`).
- `KeychainStore`, `RoutingState` / `RoutingStateStore`.

## M2 — RelayKit core

- `ProcessRunning` + `FoundationProcessRunner`
- `SettingsBackup`, `ClaudeSettingsWriter`, `VSCodeSettingsWriter`
- `LiteLLMConfigWriter`, `RelayPreferences`
- `PythonProbe`, `VenvInstaller`
- `ProxyLogStore`, `ProxyHealthChecker`, `ProxyProcessManager` (pidfile +
  `proc_pidpath` + `/health`)
- `ToggleService` coordinator

## M3 — AppKit UI

- `AppDelegate` (NSStatusItem / NSMenuDelegate, MemBar patterns)
- `RelayHeaderView` (hero + subline + status pill)
- `DeepSeekSettingsPanel`, `ProxyLogsWindowController`
- Quit stops the proxy via `applicationWillTerminate`

## M4 — Tests & docs

- Unit tests for settings writers (incl. comment-adjacent VS Code fixture),
  backup, config YAML, Python probe, venv short-circuit, proxy reconcile
  states, health checker against ephemeral socket, Keychain round-trip with
  suffixed service names, `ToggleService` DeepSeek↔Claude round-trip +
  proxy-failure rollback (Keychain skipped under SPM sandbox).
- `docs/SPEC.md`, this file.
- `build.sh` supports `SKIP_INSTALL=1` for an in-repo `.app` without touching
  `/Applications`.
- Fixed proxy `stop()` race: intentional SIGTERM no longer surfaces as
  `.failed("exited with code 15")`.
- `scripts/render-icon.swift` produces a valid `Support/AppIcon.icns`.
