#!/usr/bin/env python3
"""
Fail-safe fallback: force routing back to plain Claude, independent of whether
the Relay app or its Application Support directory is working.

Run this if Relay itself is broken/crashed and `claude` (CLI or VS Code) is
stuck pointed at a dead local proxy. Needs nothing but python3 — no Relay
app, no Swift build, no ~/Library/Application Support/Relay directory.

Usage:
    python3 revert-to-claude.py
"""
import json
import os
import shutil
import subprocess
from datetime import datetime, timezone

HOME = os.path.expanduser("~")
CLAUDE_SETTINGS = os.path.join(HOME, ".claude", "settings.json")
VSCODE_SETTINGS = os.path.join(
    HOME, "Library", "Application Support", "Code", "User", "settings.json"
)
ENV_KEYS = ("ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN")


def backup(path):
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    dest = f"{path}.{stamp}.bak"
    shutil.copy2(path, dest)
    print(f"  backed up -> {dest}")


def revert_claude_settings():
    if not os.path.exists(CLAUDE_SETTINGS):
        print(f"No {CLAUDE_SETTINGS} found — nothing to revert.")
        return

    with open(CLAUDE_SETTINGS, "r", encoding="utf-8") as f:
        raw = f.read()
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as e:
        print(f"Could not parse {CLAUDE_SETTINGS} as JSON ({e}). Not touching it — fix manually.")
        return

    env = data.get("env")
    if not isinstance(env, dict) or not any(key in env for key in ENV_KEYS):
        print("Claude CLI settings already clean — nothing to revert.")
        return

    for key in ENV_KEYS:
        env.pop(key, None)
    if env:
        data["env"] = env
    else:
        data.pop("env", None)

    backup(CLAUDE_SETTINGS)
    with open(CLAUDE_SETTINGS, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    print(f"Reverted {CLAUDE_SETTINGS} to plain Claude.")


def revert_vscode_settings():
    if not os.path.exists(VSCODE_SETTINGS):
        return

    with open(VSCODE_SETTINGS, "r", encoding="utf-8") as f:
        raw = f.read()
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        print(
            f"{VSCODE_SETTINGS} has comments or trailing commas (not strict JSON) — "
            "skipping automatic edit to avoid corrupting it. Remove the "
            "ANTHROPIC_BASE_URL / ANTHROPIC_AUTH_TOKEN entries from "
            '"claudeCode.environmentVariables" by hand, or fix Relay and use its menu.'
        )
        return

    entries = data.get("claudeCode.environmentVariables")
    if not isinstance(entries, list):
        return
    remaining = [e for e in entries if e.get("name") not in ENV_KEYS]
    if len(remaining) == len(entries):
        print("VS Code settings already clean — nothing to revert.")
        return

    backup(VSCODE_SETTINGS)
    if remaining:
        data["claudeCode.environmentVariables"] = remaining
    else:
        data.pop("claudeCode.environmentVariables", None)

    with open(VSCODE_SETTINGS, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    print(f"Reverted {VSCODE_SETTINGS} to plain Claude.")


def kill_stray_proxy():
    try:
        result = subprocess.run(["pkill", "-f", "venv/bin/litellm"], capture_output=True, text=True)
        if result.returncode == 0:
            print("Stopped a running litellm proxy process.")
    except FileNotFoundError:
        pass


def main():
    print("Reverting Relay routing to plain Claude...")
    kill_stray_proxy()
    revert_claude_settings()
    revert_vscode_settings()
    print(
        "\nDone. Already-open `claude` terminal sessions and VS Code windows "
        "won't see this until restarted."
    )


if __name__ == "__main__":
    main()
