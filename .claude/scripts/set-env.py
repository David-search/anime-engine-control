#!/usr/bin/env python3
"""Update one or more KEY=VALUE pairs in a service .env file.

Usage:  set-env.py <env_path> KEY=VALUE [KEY=VALUE ...]

Updates in place, preserving other lines + comments. If KEY isn't
present, appends. Idempotent. Safe with values containing slashes,
spaces, quotes — uses regex escaping rather than shell sed.

Exits 1 on argument errors. Always prints the keys it set so the
caller can echo them.
"""
import os
import re
import sys


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        sys.stderr.write(
            "usage: set-env.py <env_path> KEY=VALUE [KEY=VALUE ...]\n"
        )
        return 1

    env_path = argv[1]
    pairs = argv[2:]

    # Validate KEY=VALUE form, normalise
    parsed: list[tuple[str, str]] = []
    for kv in pairs:
        if "=" not in kv:
            sys.stderr.write(f"not a KEY=VALUE: {kv!r}\n")
            return 1
        key, value = kv.split("=", 1)
        if not re.fullmatch(r"[A-Z_][A-Z0-9_]*", key):
            sys.stderr.write(
                f"key {key!r} doesn't match [A-Z_][A-Z0-9_]* — refusing\n"
            )
            return 1
        parsed.append((key, value))

    if not os.path.exists(env_path):
        sys.stderr.write(f"file not found: {env_path}\n")
        return 1

    with open(env_path) as f:
        text = f.read()

    for key, value in parsed:
        pattern = re.compile(rf"^{re.escape(key)}=.*$", re.MULTILINE)
        if pattern.search(text):
            text = pattern.sub(f"{key}={value}", text)
            print(f"  updated {key} in {env_path}")
        else:
            if text and not text.endswith("\n"):
                text += "\n"
            text += f"{key}={value}\n"
            print(f"  appended {key} to {env_path}")

    with open(env_path, "w") as f:
        f.write(text)
    os.chmod(env_path, 0o600)

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
