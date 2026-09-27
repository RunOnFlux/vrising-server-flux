#!/bin/bash
# Unit tests: the pure decisions in flux-lib.sh, the BepInEx.cfg fixer, and the RCON client
# against a fake server. No Docker, no Wine, no game. Run from the repository root.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

# shellcheck source=scripts/flux-lib.sh
FLUX_LOG="" source scripts/flux-lib.sh

pass=0
fail=0
check() { # description, expected, actual
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n  expected: [%s]\n  actual:   [%s]\n' "$1" "$2" "$3"
  fi
}
status() { "$@" >/dev/null 2>&1; echo $?; }

# --- Steam branch ------------------------------------------------------------------------------
check "default branch adds no arguments" "" "$(flux_steam_branch_args default)"
check "empty branch is the default" "" "$(flux_steam_branch_args '')"
check "public is the default" "" "$(flux_steam_branch_args public)"
check "the PS5 branch" "-beta ce-1" "$(flux_steam_branch_args ce-1)"
check "a branch with a space is refused" "1" "$(status flux_steam_branch_args 'ce-1 +quit')"
check "a branch with a quote is refused" "1" "$(status flux_steam_branch_args "a'b")"

# --- Restart time ------------------------------------------------------------------------------
check "05:00 is minute 300" "300" "$(flux_restart_minute_of_day 05:00)"
check "5:07 is minute 307" "307" "$(flux_restart_minute_of_day 5:07)"
check "23:59 is the last minute" "1439" "$(flux_restart_minute_of_day 23:59)"
check "00:08 is not octal" "8" "$(flux_restart_minute_of_day 00:08)"
check "24:00 is refused" "1" "$(status flux_restart_minute_of_day 24:00)"
check "05:60 is refused" "1" "$(status flux_restart_minute_of_day 05:60)"
check "empty means no restart" "1" "$(status flux_restart_minute_of_day '')"
check "a cron line is refused" "1" "$(status flux_restart_minute_of_day '0 5 * * *')"

check "an hour ahead" "3600" "$(flux_seconds_until 300 240 0)"
check "the seconds already past count" "3570" "$(flux_seconds_until 300 240 30)"
check "earlier today means tomorrow" "82800" "$(flux_seconds_until 300 360 0)"
check "due this very minute means tomorrow" "86370" "$(flux_seconds_until 300 300 30)"
check "exactly now means tomorrow" "86400" "$(flux_seconds_until 300 300 0)"

check "warning defaults to 5" "5" "$(flux_warn_minutes '')"
check "warning is capped at 30" "30" "$(flux_warn_minutes 90)"
check "warning of 0 is allowed" "0" "$(flux_warn_minutes 0)"
check "a non-number warning is 5" "5" "$(flux_warn_minutes soon)"

# --- Restart budget ----------------------------------------------------------------------------
check "old restarts age out" "900 950" "$(flux_restarts_in_window 1000 200 100 700 900 950)"
check "no history" "" "$(flux_restarts_in_window 1000 200)"
check "a scheduled restart is not counted" "1" "$(status flux_restart_counts 'scheduled restart at 05:00')"
check "a crash is counted" "0" "$(status flux_restart_counts 'the server ended on its own (exit 137)')"

# --- Log pruning -------------------------------------------------------------------------------
check "keeps the newest" $'c\nd' "$(flux_logs_to_prune 2 a b c d)"
check "nothing to prune" "" "$(flux_logs_to_prune 5 a b c)"

# --- BepInEx.cfg -------------------------------------------------------------------------------
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"; kill "${fake_pid:-}" 2>/dev/null' EXIT
# The shape of BepInExPack_V_Rising 1.733.2's file: CRLF, no [IL2CPP] keys, console on.
printf '[Caching]\r\n\r\nEnableAssemblyCache = true\r\n\r\n[IL2CPP]\r\n\r\n## Unity version\r\nUnityBaseLibrariesSource = x\r\n\r\n[Logging.Console]\r\n\r\n## Enables showing a console\r\nEnabled = true\r\n\r\n[Logging.Disk]\r\n\r\nEnabled = true\r\n' >"${tmp}/pack.cfg"
cp "${tmp}/pack.cfg" "${tmp}/a.cfg"
check "the pack's file is updated" "updated" "$(python3 scripts/flux-bepinex-cfg.py "${tmp}/a.cfg")"
check "a second pass changes nothing" "unchanged" "$(python3 scripts/flux-bepinex-cfg.py "${tmp}/a.cfg")"
check "ScanMethodRefs is written" "1" "$(grep -c $'^ScanMethodRefs = false\r$' "${tmp}/a.cfg")"
check "PreloadIL2CPPInteropAssemblies is written" "1" "$(grep -c $'^PreloadIL2CPPInteropAssemblies = false\r$' "${tmp}/a.cfg")"
check "the console is off" "Enabled = false" "$(awk '/^\[Logging.Console\]/{f=1} f&&/^Enabled/{print; exit}' "${tmp}/a.cfg" | tr -d '\r')"
check "the disk log is left alone" "Enabled = true" "$(awk '/^\[Logging.Disk\]/{f=1} f&&/^Enabled/{print; exit}' "${tmp}/a.cfg" | tr -d '\r')"
check "no doubled carriage return" "0" "$(grep -c $'\r\r' "${tmp}/a.cfg")"
check "the keys go under [IL2CPP]" "[IL2CPP]" "$(grep -B4 '^ScanMethodRefs' "${tmp}/a.cfg" | grep '^\[' | tail -1 | tr -d '\r')"
# What the hub's sed left on live servers: "[IL2CPP]\r\r" and only ScanMethodRefs.
printf '[IL2CPP]\r\r\n\r\nScanMethodRefs = false\r\n\r\n[Logging.Console]\r\nEnabled = false\r\n' >"${tmp}/b.cfg"
python3 scripts/flux-bepinex-cfg.py "${tmp}/b.cfg" >/dev/null
check "the hub's doubled CR is repaired" "0" "$(grep -c $'\r\r' "${tmp}/b.cfg")"
check "and the missing key is added" "1" "$(grep -c '^PreloadIL2CPPInteropAssemblies = false' "${tmp}/b.cfg")"
check "ScanMethodRefs is not duplicated" "1" "$(grep -c '^ScanMethodRefs' "${tmp}/b.cfg")"
printf '[IL2CPP]\nScanMethodRefs = true\n' >"${tmp}/c.cfg"
python3 scripts/flux-bepinex-cfg.py "${tmp}/c.cfg" >/dev/null
check "an LF file stays LF" "0" "$(grep -c $'\r' "${tmp}/c.cfg")"
check "a true is turned false" "ScanMethodRefs = false" "$(grep '^ScanMethodRefs' "${tmp}/c.cfg")"
check "a missing section is appended" "1" "$(grep -c '^\[Logging.Console\]' "${tmp}/c.cfg")"

# --- RCON client, against a fake Source RCON server ----------------------------------------------
cat >"${tmp}/fake.py" <<'PY'
import socket, struct, sys
mode = sys.argv[1]
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 0)); srv.listen(5)
print(srv.getsockname()[1], flush=True)
def pkt(i, t, b=""):
    d = b.encode() + b"\0\0"; return struct.pack("<iii", len(d) + 8, i, t) + d
def read(c):
    h = c.recv(4); (n,) = struct.unpack("<i", h); d = b""
    while len(d) < n: d += c.recv(n - len(d))
    return struct.unpack("<ii", d[:8]) + (d[8:-2].decode(),)
while True:
    c, _ = srv.accept()
    i, t, body = read(c)
    c.sendall(pkt(-1 if body != "secret" else i, 2))
    if body == "secret":
        i, t, cmd = read(c)
        if mode == "reply": c.sendall(pkt(i, 0, "echo:" + cmd))
    c.close() if mode != "silent" else None
PY
python3 "${tmp}/fake.py" reply >"${tmp}/port" &
fake_pid=$!
for _ in $(seq 50); do [ -s "${tmp}/port" ] && break; sleep 0.1; done
port="$(cat "${tmp}/port")"
rcon() { VR_RCON_ENABLED=true VR_RCON_PORT="${port}" VR_RCON_PASSWORD="$1" FLUX_HOST_SETTINGS=/nonexistent FLUX_RCON_TIMEOUT=2 python3 scripts/flux-rcon.py "${@:2}"; }
check "a command gets its reply" "echo:version" "$(rcon secret version 2>/dev/null)"
check "a wrong password exits 3" "3" "$(status rcon wrong version)"
check "no RCON configured exits 2" "2" "$(VR_RCON_ENABLED=false FLUX_HOST_SETTINGS=/nonexistent status python3 scripts/flux-rcon.py version)"
check "nobody listening exits 4" "4" "$(VR_RCON_ENABLED=true VR_RCON_PORT=1 VR_RCON_PASSWORD=x FLUX_HOST_SETTINGS=/nonexistent FLUX_RCON_TIMEOUT=1 status python3 scripts/flux-rcon.py version)"
# Credentials from ServerHostSettings.json, which the game writes with a BOM.
printf '\xef\xbb\xbf{"Rcon":{"Enabled":true,"Port":%s,"Password":"secret"}}' "${port}" >"${tmp}/host.json"
check "credentials from the settings file" "echo:time" "$(env -u VR_RCON_ENABLED -u VR_RCON_PORT -u VR_RCON_PASSWORD FLUX_HOST_SETTINGS="${tmp}/host.json" FLUX_RCON_TIMEOUT=2 python3 scripts/flux-rcon.py time 2>/dev/null)"
kill "${fake_pid}" 2>/dev/null

python3 "${tmp}/fake.py" silent >"${tmp}/port2" &
fake_pid=$!
for _ in $(seq 50); do [ -s "${tmp}/port2" ] && break; sleep 0.1; done
port="$(cat "${tmp}/port2")"
check "silence after the login counts as delivered" "0" "$(status rcon secret announce hello)"

printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" = "0" ]
