#!/usr/bin/env python3
"""One Source RCON command against the V Rising server running in this container.

    flux-rcon.py <command...>

Prints the server's reply (possibly empty) and exits 0 when the command was delivered.
Exits 2 when RCON is not configured, 3 when the password is refused, 4 when the server
cannot be reached.

WHERE THE CREDENTIALS COME FROM, in the order the game itself applies them: the VR_RCON_*
environment variables, then the Rcon block of ServerHostSettings.json. The game reads the same
two sources at launch and the environment wins, so this always talks to the port and password
the server is actually using.

A REPLY IS OPTIONAL. V Rising answers some commands with no packet at all (announce, runcommand),
so silence after a successful login counts as delivered, the same rule the games hub's own RCON
client uses for V Rising (games-website src/utils/sourceRcon.js, `replyOptional`).
"""
import json
import os
import socket
import struct
import sys
import time

SETTINGS = os.environ.get(
    "FLUX_HOST_SETTINGS", "/mnt/vrising/persistentdata/Settings/ServerHostSettings.json"
)
HOST = os.environ.get("FLUX_RCON_HOST", "127.0.0.1")
TIMEOUT = float(os.environ.get("FLUX_RCON_TIMEOUT", "5"))

AUTH, EXEC, AUTH_RESPONSE = 3, 2, 2


def credentials():
    """(enabled, port, password), environment first, then the settings file."""
    rcon = {}
    try:
        with open(SETTINGS, encoding="utf-8-sig") as f:  # the game writes it with a BOM
            rcon = json.load(f).get("Rcon") or {}
    except (OSError, ValueError):
        pass
    enabled = os.environ.get("VR_RCON_ENABLED", str(rcon.get("Enabled", False)))
    port = os.environ.get("VR_RCON_PORT") or rcon.get("Port") or 25575
    password = os.environ.get("VR_RCON_PASSWORD") or rcon.get("Password") or ""
    return str(enabled).lower() == "true", int(port), str(password)


def packet(request_id, kind, body):
    data = body.encode("utf-8") + b"\x00\x00"
    return struct.pack("<iii", len(data) + 8, request_id, kind) + data


def read_packet(sock):
    header = b""
    while len(header) < 4:
        chunk = sock.recv(4 - len(header))
        if not chunk:
            raise ConnectionError("closed")
        header += chunk
    (size,) = struct.unpack("<i", header)
    data = b""
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise ConnectionError("closed")
        data += chunk
    request_id, kind = struct.unpack("<ii", data[:8])
    return request_id, kind, data[8:-2].decode("utf-8", "replace")


def run(command):
    enabled, port, password = credentials()
    if not enabled or not password:
        print("RCON is not enabled on this server", file=sys.stderr)
        return 2
    try:
        sock = socket.create_connection((HOST, port), timeout=TIMEOUT)
    except OSError as error:
        print(f"RCON unreachable on {HOST}:{port}: {error}", file=sys.stderr)
        return 4
    with sock:
        try:
            sock.sendall(packet(1, AUTH, password))
            while True:
                request_id, kind, _ = read_packet(sock)
                if kind == AUTH_RESPONSE:
                    break
            if request_id == -1:
                print("RCON password refused", file=sys.stderr)
                return 3
            sock.sendall(packet(2, EXEC, command))
        except (OSError, ConnectionError) as error:
            print(f"RCON failed: {error}", file=sys.stderr)
            return 4
        # Collect whatever comes back until a short pause: a reply has no terminator, and some
        # commands send none at all.
        sock.settimeout(0.5)
        reply = []
        deadline = time.time() + TIMEOUT
        while time.time() < deadline:
            try:
                _, _, body = read_packet(sock)
                reply.append(body)
            except (socket.timeout, ConnectionError):
                break
    print("".join(reply).strip())
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        sys.exit(64)
    sys.exit(run(" ".join(sys.argv[1:])))
