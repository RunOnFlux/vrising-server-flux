#!/bin/bash
# PID 1, and the supervisor of the V Rising server.
#
# The image this replaces (AndrewSav/vrising-docker) ended its entrypoint with
# `exec wine64 VRisingServer.exe`, so the Wine process WAS PID 1. Measured on a real server
# (2026-09-26): `docker stop` sent it SIGTERM, which it ignored; the world kept running and
# autosaving until Docker killed it ten seconds later (sixty in that test), with no save on
# exit. FluxOS stops a container with Docker's default ten seconds, so every stop, update and
# move on the network lost whatever was played since the last autosave.
#
# The game DOES save on exit when it is asked the right way: SIGINT reaches the Windows process
# through Wine as a Ctrl+C, which runs GameBootstrap.OnApplicationQuit() and SaveOnExit(). On
# the same server that took 4.7 seconds from signal to exit code 0, with
# "SaveOnExit() - Finished saving the world on exit!" in the log. So this supervisor:
#
#   - runs the server as a CHILD, never exec, so a signal to the container is ours to translate
#   - turns SIGTERM/SIGINT from Docker into SIGINT to the game, and waits for the save
#   - starts a new generation in place when the game ends (a scheduled restart, or a crash),
#     updating from Steam first, so a restart never depends on the platform noticing
#   - ends the container (exit 42) only after FLUX_RESTART_MAX_ATTEMPTS unplanned restarts
#     inside FLUX_RESTART_WINDOW seconds: a server that cannot stay up is the platform's to
#     rebuild or move
#
# Same shape as runonflux/palworld-server-flux, which does this for Palworld.

set -uo pipefail
# shellcheck source=scripts/flux-lib.sh
source /opt/flux/flux-lib.sh

FLUX_RESTART_MAX_ATTEMPTS="${FLUX_RESTART_MAX_ATTEMPTS:-5}"
FLUX_RESTART_WINDOW="${FLUX_RESTART_WINDOW:-3600}"
FLUX_RESTART_BACKOFF="${FLUX_RESTART_BACKOFF:-10}"
# How long a server asked to stop may take to save before it is killed. Docker's own deadline
# on Flux is ten seconds, so this only matters for a restart, where nobody is waiting on us.
FLUX_STOP_GRACE="${FLUX_STOP_GRACE:-60}"
STEAM_BRANCH="${STEAM_BRANCH:-default}"

s="${FLUX_SERVER_DIR}"
p="${FLUX_DATA_DIR}"
m="${FLUX_MODS_DIR}"

rm -f "${FLUX_RESTART_MARKER}"
mkdir -p "${p}" "$(dirname "${FLUX_LOG}")"
# An older image kept flux.log on the synced data volume: move it here, once.
flux_log_migrate "${p}/flux/flux.log"
flux_banner "V Rising"

flux_log "flux-entrypoint starting (image ${FLUX_IMAGE_VERSION:-dev}, wine ${FLUX_WINE_VERSION:-unknown}, steam branch ${STEAM_BRANCH})"

game_pid=""
tail_pid=""
scheduler_pid=""
interop_pid=""
terminating=0
generation=0
restart_history=()

# shellcheck disable=SC2329  # invoked by the trap below
term_handler() {
  terminating=1
  flux_log "stop requested: asking the server to save and exit, no restart will follow"
  [ -n "${game_pid}" ] && kill -INT "${game_pid}" 2>/dev/null
}
trap term_handler TERM INT

# ---------------------------------------------------------------------------------------------
# One generation's preparation: the same steps, in the same order, as the image this replaces,
# so a server moved onto this image starts from the files it already has.
# ---------------------------------------------------------------------------------------------

update_server() {
  local branch_args attempt validate
  if [ -n "${SKIP_UPDATE:-}" ] && [ -f "${s}/VRisingServer.exe" ]; then
    flux_log "SKIP_UPDATE is set: not updating the server files"
    return 0
  fi
  if ! branch_args="$(flux_steam_branch_args "${STEAM_BRANCH}")"; then
    flux_log "ERROR STEAM_BRANCH='${STEAM_BRANCH}' is not a branch name; refusing to start"
    return 1
  fi
  flux_log "updating the server from Steam (app ${FLUX_STEAM_APP}, branch ${STEAM_BRANCH})"
  # No `validate` on the first attempt. It re-hashes the whole 1.9 GB install on every start:
  # 143 s against 27 s without it, measured on the same install (2026-09-26), and a daily
  # restart paid it every day. An install that is actually broken fails the first attempt,
  # and every retry validates.
  validate=""
  for attempt in 1 2 3 4 5; do
    # shellcheck disable=SC2086  # branch_args is "" or "-beta <name>", validate "" or "validate"
    if steamcmd +@sSteamCmdForcePlatformType windows +force_install_dir "${s}" +login anonymous \
      +app_update "${FLUX_STEAM_APP}" ${branch_args} ${validate} +quit; then
      return 0
    fi
    validate="validate"
    flux_log "WARN steamcmd failed (attempt ${attempt}/5); retrying in 5s with validate"
    rm -rf "${s}/steamapps"
    sleep 5
  done
  # A server that already has its files can still run the build it has.
  if [ -f "${s}/VRisingServer.exe" ]; then
    flux_log "WARN could not update from Steam; starting the build already installed"
    return 0
  fi
  flux_log "ERROR could not install the server from Steam"
  return 1
}

prepare_files() {
  # Upstream's fix for CPUs without AVX, kept as it was.
  if ! grep -q -o 'avx[^ ]*' /proc/cpuinfo; then
    local unsupported="VRisingServer_Data/Plugins/x86_64/lib_burst_generated.dll"
    if [ -f "${s}/${unsupported}" ]; then
      flux_log "no AVX on this CPU: disabling ${unsupported}"
      mv "${s}/${unsupported}" "${s}/${unsupported}.bak"
    fi
  fi

  mkdir -p "${p}/Settings"
  local f
  for f in ServerGameSettings.json ServerHostSettings.json; do
    if [ ! -f "${p}/Settings/${f}" ]; then
      flux_log "${f} not found: copying the server's defaults"
      cp "${s}/VRisingServer_Data/StreamingAssets/Settings/${f}" "${p}/Settings/" 2>/dev/null
    fi
  done

  # Mods, exactly as the previous image did them: the install copy is wiped and, with
  # ENABLE_MODS, copied again from the mods volume. The games hub's Mods tab writes only there.
  rm -rf "${s}/BepInEx" "${s}/dotnet"
  rm -f "${s}/doorstop_config.ini" "${s}/winhttp.dll"
  unset WINEDLLOVERRIDES
  if [ -n "${ENABLE_MODS:-}" ] && [ -d "${m}/BepInEx" ]; then
    flux_log "ENABLE_MODS: installing BepInEx and plugins from ${m}"
    # The three settings BepInEx needs under Wine and in the plan's memory, on the mods volume's
    # own file so they stick. See flux-bepinex-cfg.py for why this is not left to the hub.
    if [ -f "${m}/BepInEx/config/BepInEx.cfg" ]; then
      flux_log "BepInEx.cfg: $(python3 /opt/flux/flux-bepinex-cfg.py "${m}/BepInEx/config/BepInEx.cfg" 2>&1)"
    fi
    cp -r "${m}/BepInEx" "${s}/BepInEx"
    [ -d "${m}/dotnet" ] && cp -r "${m}/dotnet" "${s}/dotnet"
    [ -f "${m}/doorstop_config.ini" ] && cp "${m}/doorstop_config.ini" "${s}/doorstop_config.ini"
    [ -f "${m}/winhttp.dll" ] && cp "${m}/winhttp.dll" "${s}/winhttp.dll"
    export WINEDLLOVERRIDES="winhttp=n,b"
  elif [ -n "${ENABLE_MODS:-}" ]; then
    flux_log "ENABLE_MODS is set but ${m}/BepInEx does not exist yet: starting without mods"
  fi

  flux_prune_game_logs
}

# BepInEx's generated interop assemblies, kept across restarts. They are generated inside the
# INSTALL copy of BepInEx, which the step above wipes on every start, so without this every
# restart regenerated them (minutes, and the memory peak of a modded server). When a generation
# finishes (assembly-hash.txt is written last), the result is copied back to the mods volume,
# swapped in with a rename so a restart mid-copy never leaves half a folder to trust.
interop_sync_loop() {
  local S="${s}/BepInEx" M="${m}/BepInEx" h
  while :; do
    h="${S}/interop/assembly-hash.txt"
    if [ -d "${M}" ] && [ -f "${h}" ] && ! cmp -s "${h}" "${M}/interop/assembly-hash.txt"; then
      rm -rf "${M}/.i" "${M}/.u"
      if cp -r "${S}/interop" "${M}/.i" && cp -r "${S}/unity-libs" "${M}/.u"; then
        rm -rf "${M}/interop" "${M}/unity-libs"
        mv "${M}/.i" "${M}/interop" && mv "${M}/.u" "${M}/unity-libs"
        flux_log "BepInEx interop assemblies saved to the mods volume; later starts reuse them"
      fi
    fi
    sleep 5
  done
}

start_display() {
  if ! pgrep -x Xvfb >/dev/null 2>&1; then
    rm -f /tmp/.X0-lock
    Xvfb :0 -screen 0 1024x768x16 >/dev/null 2>&1 &
  fi
  # winecfg only builds the prefix. Once it exists there is nothing for it to do, and it cost
  # every start of the previous image five seconds.
  if [ ! -d "${WINEPREFIX:-${HOME}/.wine}/drive_c" ]; then
    flux_log "creating the Wine prefix"
    winecfg >/dev/null 2>&1
    sleep 5
  fi
}

start_generation() {
  local log_file
  generation=$((generation + 1))
  rm -f "${FLUX_RESTART_MARKER}"

  update_server || return 1
  # A stop that arrived during the Steam update: there is no world running to save, and
  # starting one now would only be killed mid-load.
  [ "${terminating}" = "1" ] && return 2
  prepare_files
  start_display

  # Same log name as before: the games hub reads the build number from the newest
  # persistentdata/*.log.
  log_file="${p}/$(date +%Y%m%d-%H%M%S)-VRisingServer.log"
  : >"${log_file}"
  flux_banner "V Rising"
  flux_log "starting the server (generation ${generation}), log ${log_file}"
  DISPLAY=:0.0 wine64 "${s}/VRisingServer.exe" -persistentDataPath "${p}" -logFile "${log_file}" >/dev/null 2>&1 &
  game_pid=$!

  # The game's log on the container's output, so the platform's app log shows the server
  # rather than nothing at all.
  tail -n +1 -F "${log_file}" 2>/dev/null &
  tail_pid=$!

  if [ -n "${ENABLE_MODS:-}" ]; then
    interop_sync_loop &
    interop_pid=$!
  fi

  /opt/flux/flux-scheduler.sh &
  scheduler_pid=$!
  return 0
}

sweep_generation() {
  local pid
  for pid in "${scheduler_pid}" "${interop_pid}" "${tail_pid}"; do
    [ -n "${pid}" ] && kill "${pid}" 2>/dev/null
  done
  scheduler_pid="" interop_pid="" tail_pid=""
  # Whatever Wine left behind for this generation.
  pkill -KILL -f "${FLUX_GAME_PROCESS}" 2>/dev/null
  wineserver -k 2>/dev/null
}

# Waits for the game to end. A requested stop or restart that is not honoured within
# FLUX_STOP_GRACE ends it by force.
wait_for_generation() {
  local asked_at=0 now
  while kill -0 "${game_pid}" 2>/dev/null; do
    sleep 1
    if [ "${terminating}" = "1" ] || [ -f "${FLUX_RESTART_MARKER}" ]; then
      now="$(date -u +%s)"
      [ "${asked_at}" = "0" ] && asked_at="${now}"
      if [ $((now - asked_at)) -ge "${FLUX_STOP_GRACE}" ]; then
        flux_log "WARN the server was asked to stop ${FLUX_STOP_GRACE}s ago and has not; ending it"
        kill -KILL "${game_pid}" 2>/dev/null
      fi
    fi
  done
  wait "${game_pid}" 2>/dev/null
}

while true; do
  # A stop that arrived during the restart backoff: exit now rather than run a Steam update
  # that Docker will kill anyway.
  if [ "${terminating}" = "1" ]; then
    flux_log "stopped on request before the server started"
    exit 0
  fi
  start_generation
  started=$?
  if [ "${started}" = "2" ]; then
    flux_log "stopped on request before the server started"
    exit 0
  elif [ "${started}" != "0" ]; then
    # Nothing to run. A container that cannot install the game is the platform's problem.
    flux_log "ERROR the server could not be prepared; ending the container (42)"
    exit 42
  fi
  wait_for_generation
  rc=$?

  reason=""
  if [ -f "${FLUX_RESTART_MARKER}" ]; then
    reason="$(cat "${FLUX_RESTART_MARKER}" 2>/dev/null)"
  fi
  sweep_generation
  rm -f "${FLUX_RESTART_MARKER}"

  if [ "${terminating}" = "1" ]; then
    flux_log "stopped on request (server exited ${rc})"
    exit 0
  fi

  [ -z "${reason}" ] && reason="the server ended on its own (exit ${rc})"

  if flux_restart_counts "${reason}"; then
    now="$(date -u +%s)"
    read -r -a restart_history <<<"$(flux_restarts_in_window "${now}" "${FLUX_RESTART_WINDOW}" "${restart_history[@]}")"
    restart_history+=("${now}")
    if [ "${#restart_history[@]}" -gt "${FLUX_RESTART_MAX_ATTEMPTS}" ]; then
      flux_log "${reason}: ${#restart_history[@]} restarts within ${FLUX_RESTART_WINDOW}s, so restarting it here is not working. Ending the container so the platform can rebuild or move it (42)."
      exit 42
    fi
  fi

  flux_log "${reason}: restarting the server in place in ${FLUX_RESTART_BACKOFF}s"
  # In the background and waited on: bash runs a trap only after a foreground command ends, so a
  # plain sleep here would hold a stop for the whole backoff, which is Docker's whole deadline.
  sleep "${FLUX_RESTART_BACKOFF}" &
  wait $!
done
