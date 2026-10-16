# vrising-server-flux

The V Rising dedicated server image the [Flux](https://runonflux.io/) marketplace and the
[games hub](https://runonflux.com/games/vrising) deploy: `runonflux/vrising-server-flux`.

It runs the server the usual way on Linux, the Windows `VRisingServer.exe` under Wine (10.0 staging-tkg with fsync, see the Dockerfile),
installed and updated with SteamCMD on every start. It keeps the volumes, paths, settings and
mod layout of the image the marketplace used before (AndrewSav/vrising-docker), so a server
can move onto it without touching its files. It was written from scratch rather than forked.

## What it adds

| | Previous image | This image |
|---|---|---|
| `docker stop` | Ignored: Wine was PID 1 and the server never saw the signal. Killed after the timeout, with no save | The server gets Ctrl+C (SIGINT), runs its own save on exit and quits: 3.7 to 6.3 s over four stops on a real server, with and without BepInEx mods, inside Flux's 10 s |
| Server crashes | The container ends, and the platform has to notice | Restarted in place in about 50 s; the container only ends after 5 crashes in an hour (exit 42) |
| Daily restart | None | `FLUX_RESTART_TIME`, with the game's own translated warning to players first |
| Updates | On container start, with a full `validate` (143 s) | On every start of the server, scheduled restarts included, without `validate` (27 s); a failed update retries with it |
| BepInEx interop assemblies | Regenerated on every start (minutes, and the memory peak) | Kept on the mods volume and reused until the game updates |
| BepInEx.cfg | Left to whoever installed it | The three settings BepInEx needs here are enforced on every start |
| App log | Empty: the game logged to a file only | The game's log, plus the supervisor's |
| Game logs | One per start, never deleted | The newest 10 kept |
| PlayStation 5 build | No | `STEAM_BRANCH=ce-1` |
| RCON from inside | No client | `flux-rcon <command>` |

## Configuration

Everything the game reads is unchanged: the `VR_*` variables from Stunlock's
[dedicated server instructions](https://github.com/StunlockStudios/vrising-dedicated-server-instructions),
`ENABLE_MODS`, `SKIP_UPDATE`, and the settings files in `persistentdata/Settings`.

| Variable | Default | |
|---|---|---|
| `FLUX_RESTART_TIME` | empty (off) | Daily restart, `HH:MM`, 24 hour, in `TZ` |
| `FLUX_RESTART_WARN_MINUTES` | `5` | Warning before it, 0 to 30. Sent with `announcerestart` at the start and again at one minute |
| `TZ` | UTC | Timezone of `FLUX_RESTART_TIME` |
| `STEAM_BRANCH` | `default` | `default` for PC, `ce-1` for the PlayStation 5 build |
| `FLUX_STOP_GRACE` | `60` | Seconds a restart may take to save before it is forced. Docker's own stop timeout still applies to `docker stop` |
| `FLUX_RESTART_MAX_ATTEMPTS` / `FLUX_RESTART_WINDOW` | `5` / `3600` | Unplanned restarts allowed per window before the container ends with 42 |
| `FLUX_GAME_LOG_KEEP` | `10` | Game logs kept in `persistentdata` |

Volumes: `/mnt/vrising/server` (the install), `/mnt/vrising/persistentdata` (settings, saves,
logs), `/mnt/vrising/mods` (BepInEx and plugins, copied into the install when `ENABLE_MODS` is set).

## How a stop and a restart work

Measured on a real server, and the reason this image exists:

- **SIGINT is the only fast clean exit.** It reaches the Windows process as Ctrl+C, and the game
  runs `GameBootstrap.OnApplicationQuit()` and `SaveOnExit()`. SIGTERM does nothing.
- **RCON `shutdown` saves too, but takes whole minutes** (`shutdown <minutes[,minutes]> <message>`,
  1 at least), so it cannot answer a 10 second stop.
- **RCON answers before the world has loaded**, and in that window `shutdown` fails with
  `no ServerTime component found`. A warning that cannot be sent is logged and the restart goes
  ahead anyway.
- **A stop in the first seconds after the world loads writes no save.** The log shows
  `SaveOnExit() - Finalizing` without `Saving the world on exit!`. Nothing has been played yet at
  that point, so nothing is lost; stopped after its first autosave, the server always saved.

The scheduled restart warns with `announcerestart`, sends SIGINT at the time, and the supervisor
starts the next generation: SteamCMD update, then the server. The container stays up throughout.

## Development

```bash
./tests/test-flux.sh                                         # pure logic, the cfg fixer, RCON against a fake server
docker build -t vrising-server-flux:local .
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -x scripts/*.sh tests/*.sh
```

CI (`.github/workflows/build.yml`) runs the tests on every push and pull request, and publishes
`:latest` and `:<commit>` on every push to `main` and weekly. It needs `DOCKERHUB_USERNAME` and
`DOCKERHUB_TOKEN`.
