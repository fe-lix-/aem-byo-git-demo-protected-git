#!/usr/bin/env python3
"""Configure an EDS site's Cloud Manager BYO Git source (Python standard library)."""

import argparse
import http.client
import json
import os
import sys
import termios
from urllib.parse import quote


def read_hidden_token():
    """Read long pasted tokens without the terminal's canonical line limit."""
    with open("/dev/tty", "r+b", buffering=0) as terminal:
        fd = terminal.fileno()
        original = termios.tcgetattr(fd)
        settings = termios.tcgetattr(fd)
        settings[0] &= ~(termios.IGNCR | termios.INLCR | termios.IXON)
        settings[0] |= termios.ICRNL
        settings[3] &= ~(termios.ECHO | termios.ECHONL | termios.ICANON)
        settings[6][termios.VMIN] = 1
        settings[6][termios.VTIME] = 0
        data = bytearray()
        try:
            termios.tcsetattr(fd, termios.TCSANOW, settings)
            terminal.write(b"Paste x-auth-token (hidden), then press Enter: ")
            while True:
                chunk = os.read(fd, 4096)
                if not chunk:
                    raise EOFError
                for char in chunk:
                    if char in (10, 13):
                        return data.decode("ascii").strip()
                    if char == 4:  # Ctrl+D
                        raise EOFError
                    if char == 3:  # Ctrl+C if terminal signals are disabled
                        raise KeyboardInterrupt
                    if char in (8, 127):
                        if data:
                            data.pop()
                    else:
                        data.append(char)
                    if len(data) > 65536:
                        raise ValueError("Token exceeds the 64 KiB input limit")
        finally:
            termios.tcsetattr(fd, termios.TCSAFLUSH, original)
            terminal.write(b"\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--org", required=True, help="EDS organization")
    parser.add_argument("--site", required=True, help="EDS site")
    parser.add_argument("--program-id", required=True, help="Cloud Manager program ID")
    parser.add_argument("--repo-id", required=True, help="Cloud Manager repository ID")
    args = parser.parse_args()
    for name, value in vars(args).items():
        if not value.strip():
            parser.error(f"--{name.replace('_', '-')} must not be empty")

    cm_secret = os.environ.get("CM_SECRET")
    if cm_secret is None or not cm_secret.strip():
        parser.error("Set CM_SECRET to the secret from Cloud Manager")

    token = os.environ.get("HLX_TOKEN")
    if token is not None:
        token = token.strip()
    else:
        if not sys.stdin.isatty():
            parser.error("Set HLX_TOKEN or run interactively to enter the token securely")
        try:
            token = read_hidden_token()
        except (ValueError, OSError):
            parser.error("Could not read token; use a macOS/Linux terminal and an ASCII token under 64 KiB")
    if not token or any(ord(char) < 33 or ord(char) > 126 for char in token):
        parser.error("Token must be nonempty and contain only printable ASCII without spaces")

    payload = json.dumps({
        "source": {
            "url": "https://cm-repo.adobe.io/api",
            "raw_url": "https://cm-repo.adobe.io/api/raw",
            "owner": args.program_id,
            "repo": args.repo_id,
            "type": "byogit",
            "secretId": "cm-byog",
        }
    }).encode("utf-8")
    base_path = (
        f"/config/{quote(args.org, safe='')}/sites/"
        f"{quote(args.site, safe='')}"
    )
    requests = [
        ("Cloud Manager secret", f"{base_path}/secrets/cm-byog.json",
         json.dumps({"value": cm_secret}).encode("utf-8")),
        ("BYO Git source configuration", f"{base_path}/code.json", payload),
    ]
    for label, path, body in requests:
        connection = http.client.HTTPSConnection("admin.hlx.page", timeout=60)
        print(f"Updating {label} (timeout: 60 seconds)...", flush=True)
        try:
            connection.request("POST", path, body=body, headers={
                "content-type": "application/json",
                "x-auth-token": token,
            })
            response = connection.getresponse()
            # Never log response bodies: the API may echo submitted secrets.
            response.read()
            print(f"{label}: HTTP {response.status}")
            if not 200 <= response.status < 300:
                print(f"{label} failed; stopping. Redirects are not followed.", file=sys.stderr)
                return 1
        except (OSError, http.client.HTTPException):
            # Exception messages can contain request data; do not print them.
            print(f"{label}: HTTPS request failed; stopping.", file=sys.stderr)
            return 1
        finally:
            connection.close()
    print("Cloud Manager secret and BYO Git source configuration updated.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (KeyboardInterrupt, EOFError):
        print("\nCancelled.", file=sys.stderr)
        sys.exit(130)
