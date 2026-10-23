#!/usr/bin/env python3
"""Post the current version's changelog to Discord after a release.

Called by release.bat. Reads the version from argv[1] (falls back to version.txt),
pulls that entry's title + notes out of scripts/Changelog.gd, and POSTs them to
the Discord webhook taken from the VIKINGVALE_DISCORD_WEBHOOK env var or a local
.discord_webhook file (both gitignored). If no webhook is configured it prints a
notice and exits 0 — it must NEVER fail a release.

Stdlib only (urllib) so it runs anywhere Python does, no pip installs.
"""
import json
import os
import re
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DISCORD_LIMIT = 2000


def read_webhook() -> str:
    hook = os.environ.get("VIKINGVALE_DISCORD_WEBHOOK", "").strip()
    if hook:
        return hook
    path = os.path.join(ROOT, ".discord_webhook")
    if os.path.isfile(path):
        with open(path, encoding="utf-8") as f:
            return f.read().strip()
    return ""


def read_version() -> str:
    if len(sys.argv) > 1 and sys.argv[1].strip():
        return sys.argv[1].strip().lstrip("vV")
    with open(os.path.join(ROOT, "version.txt"), encoding="utf-8") as f:
        return f.read().strip()


def parse_entry(version: str):
    """Return (title, [notes]) for `version` from Changelog.gd, or ('', [])."""
    with open(os.path.join(ROOT, "scripts", "Changelog.gd"), encoding="utf-8") as f:
        src = f.read()
    vidx = src.find('"version": "%s"' % version)
    if vidx < 0:
        return "", []
    # Bound the search to this entry so we don't bleed into the next version.
    nxt = src.find('"version":', vidx + 1)
    block = src[vidx: nxt if nxt > 0 else len(src)]
    tmatch = re.search(r'"title":\s*"([^"]*)"', block)
    title = tmatch.group(1) if tmatch else ""
    notes = []
    nstart = block.find('"notes"')
    if nstart >= 0:
        lb = block.find("[", nstart)
        rb = block.find("]", lb)
        if lb >= 0 and rb > lb:
            notes = re.findall(r'"([^"]*)"', block[lb + 1: rb])
    return title, notes


def build_content(version: str, title: str, notes: list) -> str:
    if not notes:
        return "**VikingVale v%s** is out! The updater will pull it on next launch." % version
    header = "**VikingVale v%s%s**\n\n" % (
        version, (" — " + title) if title else "")
    body = "\n".join("• " + n for n in notes)
    content = header + body
    if len(content) > DISCORD_LIMIT:
        content = content[: DISCORD_LIMIT - 2].rstrip() + "…"
    return content


def post(hook: str, content: str) -> int:
    data = json.dumps({"content": content}).encode("utf-8")
    # A real User-Agent is REQUIRED: Discord/Cloudflare 403s the default
    # "Python-urllib/x.y" UA. (PowerShell's Invoke-RestMethod worked earlier only
    # because it sends a browser-like UA.)
    req = urllib.request.Request(hook, data=data, headers={
        "Content-Type": "application/json",
        "User-Agent": "VikingVale-Release/1.0 (+https://github.com/shrimpey94/VikingVale)",
    })
    with urllib.request.urlopen(req, timeout=10) as resp:
        return resp.status


def main() -> int:
    hook = read_webhook()
    if not hook:
        print("No Discord webhook configured (set VIKINGVALE_DISCORD_WEBHOOK or "
              ".discord_webhook) — skipping announcement.")
        return 0
    version = read_version()
    title, notes = parse_entry(version)
    content = build_content(version, title, notes)
    try:
        status = post(hook, content)
        print("Discord announcement posted (HTTP %s)." % status)
    except Exception as e:  # noqa: BLE001 — a failed ping must not fail the release
        print("Discord post failed (release itself is fine): %s" % e)
    return 0


if __name__ == "__main__":
    sys.exit(main())
