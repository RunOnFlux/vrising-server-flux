# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A **Docker image repo**, not an application: the V Rising dedicated server for Flux,
`runonflux/vrising-server-flux`. Ubuntu 22.04, WineHQ Wine (pinned), SteamCMD, and a
supervisor in bash. Same family as `~/work/palworld-server-flux`, which does this for Palworld;
read it for the patterns this one follows.

The rule that shapes everything: **the container supervises its own server.** PID 1 is
`flux-entrypoint.sh`, never the game. The game runs as a child so a stop can be translated into
the one signal it saves on, and a finished generation is followed by the next one in place.

## Commands

```bash
./tests/test-flux.sh
docker build -t vrising-server-flux:local .
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -x scripts/*.sh tests/*.sh
```

## The files

- `scripts/flux-entrypoint.sh`: PID 1. Per generation: SteamCMD update, settings defaults, mods,
  Xvfb and the Wine prefix, then `wine64 VRisingServer.exe` in the background, the log tail, the
  interop sync loop and the scheduler. SIGTERM/SIGINT become SIGINT to the game.
- `scripts/flux-scheduler.sh`: the daily restart (`FLUX_RESTART_TIME`).
- `scripts/flux-lib.sh`: shared helpers. **Sourcing it must stay side-effect free**: the tests
  source it directly. Every decision takes its inputs as arguments.
- `scripts/flux-rcon.py`: a Source RCON client, `flux-rcon` on the PATH.
- `scripts/flux-bepinex-cfg.py`: makes BepInEx.cfg hold the three settings BepInEx needs here.

## Things that will bite you

- **Only SIGINT saves quickly.** SIGTERM is ignored by the game under Wine, and RCON `shutdown`
  takes whole minutes. Verified on a real server; see README "How a stop and a restart work".
- **Wine is pinned** (`WINE_VERSION` in the Dockerfile). An unpinned rebuild pulled Wine 11,
  which has no `wine64` launcher, and every start failed with exit 127. Move it deliberately,
  test on a real server, and keep the CI smoke test in step.
- **The games hub depends on these paths and names.** It reads the build number from the newest
  `persistentdata/*.log`, detects the server with `pgrep -f VRisingServer.exe`, and its Mods tab
  writes to `/mnt/vrising/mods`. So our own log lives in `persistentdata/flux/`, never next to the
  game's logs, and the game log keeps the `<date>-VRisingServer.log` name.
- **The hub's old BepInEx.cfg sed was broken** (doubled CR after `[IL2CPP]`, so
  `PreloadIL2CPPInteropAssemblies` was never written). `flux-bepinex-cfg.py` repairs that file;
  keep the CRLF handling when touching it.
- **RCON answers before the world has loaded.** Anything sent then may fail; never make a
  restart depend on an RCON reply.
- **No `validate` on the first SteamCMD attempt** (143 s vs 27 s per start); retries validate.
  Don't put it back unconditionally: every daily restart pays it.
- **`/entrypoint.sh` is a compatibility symlink.** Hub specs made for the previous image carry
  `commands` ending in `exec /entrypoint.sh`; removing it breaks those apps.
- **Flux stops a container with Docker's default 10 seconds** (FluxOS sets no StopTimeout).
  SIGINT saves within that: 3.7 to 6.3 s over four real stops (2026-09-26/27). The margin is
  not huge; anything added to the stop path has to fit in it.
- **A stop seconds after the world loads writes no save** (the log has "Finalizing" but not
  "Saving the world on exit!"). Stopped after the first autosave, it always saved. Don't read
  that first case as a broken stop when testing.
