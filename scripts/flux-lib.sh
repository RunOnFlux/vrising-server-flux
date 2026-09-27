#!/bin/bash
# Shared helpers for the V Rising image.
#
# SOURCING THIS FILE MUST STAY SIDE-EFFECT FREE: tests/test-flux.sh sources it directly and
# calls the functions with made-up inputs. Everything that decides something takes its inputs
# as arguments, so the decision can be tested without a server, Wine or Docker.

# ---------------------------------------------------------------------------------------------
# Paths. The three volumes are the ones the marketplace spec mounts and the games hub's panel
# reads (games-website src/games/vrising): do not move them.
# ---------------------------------------------------------------------------------------------
FLUX_SERVER_DIR="${FLUX_SERVER_DIR:-/mnt/vrising/server}"
FLUX_DATA_DIR="${FLUX_DATA_DIR:-/mnt/vrising/persistentdata}"
FLUX_MODS_DIR="${FLUX_MODS_DIR:-/mnt/vrising/mods}"
# Our own log sits in a SUBFOLDER on purpose. The hub finds the game's log as the newest
# `persistentdata/*.log` (it reads the build number out of it), so a log of ours in the same
# folder would be picked instead of the game's.
FLUX_LOG="${FLUX_LOG:-${FLUX_DATA_DIR}/flux/flux.log}"
FLUX_LOG_MAX_LINES="${FLUX_LOG_MAX_LINES:-2000}"
# The game's own logs, one per start, named by start time. Nothing ever deleted them.
FLUX_GAME_LOG_KEEP="${FLUX_GAME_LOG_KEEP:-10}"
FLUX_GAME_PROCESS="${FLUX_GAME_PROCESS:-VRisingServer.exe}"
FLUX_STEAM_APP="${FLUX_STEAM_APP:-1829350}"
FLUX_RCON="${FLUX_RCON:-/opt/flux/flux-rcon.py}"
FLUX_RESTART_MARKER="${FLUX_RESTART_MARKER:-/tmp/flux-restart-requested}"

flux_log() {
  local line
  line="$(date -u '+%Y-%m-%dT%H:%M:%SZ') [flux] $*"
  printf '%s\n' "${line}"
  if [ -n "${FLUX_LOG}" ] && mkdir -p "$(dirname "${FLUX_LOG}")" 2>/dev/null; then
    printf '%s\n' "${line}" >>"${FLUX_LOG}" 2>/dev/null || return 0
    flux_trim_file "${FLUX_LOG}" "${FLUX_LOG_MAX_LINES}"
  fi
}

# Keeps the last $2 lines of $1. Checked cheaply first: most calls change nothing.
flux_trim_file() {
  local file="$1" max="$2" lines
  lines="$(wc -l <"${file}" 2>/dev/null || echo 0)"
  if [ "${lines}" -gt $((max + max / 10)) ]; then
    tail -n "${max}" "${file}" >"${file}.tmp" 2>/dev/null && mv "${file}.tmp" "${file}"
  fi
}

# ---------------------------------------------------------------------------------------------
# Steam branch. `default` is the PC game. `ce-1` is the build for the PlayStation 5 version,
# the same Windows server on another branch of the same app (Stunlock's 1.1.x-ps5
# instructions). Anything else is refused rather than passed to SteamCMD.
# ---------------------------------------------------------------------------------------------

# $1 = the requested branch. Prints the SteamCMD arguments for it (nothing for the default
# branch). Returns 1 for a value that is not a branch name.
flux_steam_branch_args() {
  local branch="${1:-default}"
  case "${branch}" in
    default | public | '') return 0 ;;
  esac
  if [[ ! "${branch}" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then
    return 1
  fi
  printf -- '-beta %s' "${branch}"
}

# ---------------------------------------------------------------------------------------------
# The scheduled restart.
# ---------------------------------------------------------------------------------------------

# $1 = "HH:MM" (24 hour). Prints the minutes after midnight. Returns 1 for anything else,
# including an empty value, which means "no scheduled restart".
flux_restart_minute_of_day() {
  local value="$1" h m
  [[ "${value}" =~ ^([0-9]{1,2}):([0-9]{2})$ ]] || return 1
  h=$((10#${BASH_REMATCH[1]}))
  m=$((10#${BASH_REMATCH[2]}))
  [ "${h}" -le 23 ] && [ "${m}" -le 59 ] || return 1
  printf '%s' $((h * 60 + m))
}

# $1 = minute of the day the restart is set for, $2 = the current minute of the day,
# $3 = the current second of that minute. Prints how many seconds until the next restart, in
# the same timezone both minutes were taken in. A restart due this very minute is tomorrow's:
# otherwise a server that restarts at 05:00 and is back up at 05:00:40 restarts again.
flux_seconds_until() {
  local target="$1" now_min="$2" now_sec="${3:-0}" delta
  delta=$(((target - now_min) * 60 - now_sec))
  [ "${delta}" -le 0 ] && delta=$((delta + 86400))
  printf '%s' "${delta}"
}

# $1 = the warning the owner asked for, in minutes. Prints it clamped to 0..30: V Rising's
# announcerestart takes whole minutes, and a longer warning mostly keeps a server that is due
# for its update from getting it.
flux_warn_minutes() {
  local value="${1:-5}"
  [[ "${value}" =~ ^[0-9]+$ ]] || value=5
  [ "${value}" -gt 30 ] && value=30
  printf '%s' "${value}"
}

# ---------------------------------------------------------------------------------------------
# The supervisor's restart budget: a server that keeps dying is not fixed by restarting it in
# the same container forever.
# ---------------------------------------------------------------------------------------------

# $1 = now (epoch seconds), $2 = window in seconds, $3.. = the times of earlier restarts.
# Prints the restarts that are still inside the window, space separated.
flux_restarts_in_window() {
  local now="$1" window="$2" t kept=()
  shift 2
  for t in "$@"; do
    [ "${t}" -gt $((now - window)) ] && kept+=("${t}")
  done
  printf '%s' "${kept[*]}"
}

# $1 = why the last generation ended. Only a server that ended on its own counts against the
# budget: a scheduled restart is the plan working, and a stop was asked for.
flux_restart_counts() {
  case "$1" in
    scheduled*) return 1 ;;
    *) return 0 ;;
  esac
}

# ---------------------------------------------------------------------------------------------
# The game's logs.
# ---------------------------------------------------------------------------------------------

# $1 = number to keep, then the log files NEWEST FIRST. Prints the ones to delete.
flux_logs_to_prune() {
  local keep="$1" i=0 f
  shift
  for f in "$@"; do
    i=$((i + 1))
    [ "${i}" -gt "${keep}" ] && printf '%s\n' "${f}"
  done
  return 0
}

flux_prune_game_logs() {
  local f logs=()
  # shellcheck disable=SC2012  # names are ours: <date>-VRisingServer.log, no spaces
  mapfile -t logs < <(ls -t "${FLUX_DATA_DIR}"/*-VRisingServer.log 2>/dev/null)
  while IFS= read -r f; do
    [ -n "${f}" ] && rm -f "${f}"
  done < <(flux_logs_to_prune "${FLUX_GAME_LOG_KEEP}" "${logs[@]}")
}

# ---------------------------------------------------------------------------------------------
# The running server.
# ---------------------------------------------------------------------------------------------

flux_game_pid() {
  pgrep -f "${FLUX_GAME_PROCESS}" 2>/dev/null | head -1
}

# One RCON command, quietly. Prints the reply; returns the client's status.
flux_rcon() {
  python3 "${FLUX_RCON}" "$@" 2>/dev/null
}
