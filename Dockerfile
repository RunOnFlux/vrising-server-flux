# V Rising dedicated server image for Flux.
#
# Written from scratch. It runs the same way as the image the Flux marketplace deployed before
# (AndrewSav/vrising-docker): the Windows server under WineHQ Wine, installed and updated with
# SteamCMD on every start, on the same three volumes. What it adds is a supervisor that saves the
# world on stop, restarts in place, restarts on a schedule, keeps BepInEx's generated files, and
# can install the PlayStation 5 build (STEAM_BRANCH=ce-1). See README.md.
# The base. CI builds it pinned to the digest it resolved and records that digest in the
# org.opencontainers.image.base.digest label, which the scheduled check compares against
# (.github/ci/needs-rebuild.sh).
ARG BASE_IMAGE=ubuntu:22.04
FROM ${BASE_IMAGE}

ARG DEBIAN_FRONTEND=noninteractive
ARG FLUX_IMAGE_VERSION=dev
# PINNED, not "whatever winehq-stable is today". 10.0 is what the previous image ran and what
# this server and its BepInEx mods were verified on. An unpinned build on 2026-09-26 pulled 11.0,
# which drops the wine64 launcher the server was started with, and every start failed with 127.
# Moving Wine is a deliberate change, tested on a real server, never a side effect of a rebuild.
ARG WINE_VERSION=10.0.0.0~jammy-1

# WineHQ's own packages, as before: the distribution's Wine is too old for this server.
RUN echo steam steam/question select "I AGREE" | debconf-set-selections && \
    echo steam steam/license note '' | debconf-set-selections && \
    apt-get update -y && \
    apt-get upgrade -y --no-install-recommends && \
    apt-get install -y --no-install-recommends ca-certificates wget gnupg software-properties-common && \
    add-apt-repository -y multiverse && \
    dpkg --add-architecture i386 && \
    mkdir -pm755 /etc/apt/keyrings && \
    wget -qO /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key && \
    wget -qNP /etc/apt/sources.list.d/ https://dl.winehq.org/wine-builds/ubuntu/dists/jammy/winehq-jammy.sources && \
    apt-get update -y && \
    apt-get install -y --install-recommends \
        winehq-stable=${WINE_VERSION} wine-stable=${WINE_VERSION} \
        wine-stable-amd64=${WINE_VERSION} wine-stable-i386:i386=${WINE_VERSION} && \
    apt-get install -y --no-install-recommends \
        libgl1-mesa-glx:i386 steamcmd winbind xvfb tzdata procps python3-minimal && \
    apt-get remove -y --purge wget gnupg software-properties-common && \
    apt-get autoremove -y && apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    ln -s /usr/games/steamcmd /usr/bin/steamcmd

COPY scripts/flux-lib.sh scripts/flux-entrypoint.sh scripts/flux-scheduler.sh scripts/flux-rcon.py scripts/flux-bepinex-cfg.py /opt/flux/
# /entrypoint.sh is the previous image's start command. The games hub wraps it in the spec's
# `commands` for apps deployed on that image (`bash -c "...; exec /entrypoint.sh"`), and a spec
# keeps its commands when only the repotag changes, so without this name such an app would not
# start on this image.
RUN chmod 0755 /opt/flux/*.sh /opt/flux/*.py && \
    ln -s /opt/flux/flux-rcon.py /usr/local/bin/flux-rcon && \
    ln -s /opt/flux/flux-entrypoint.sh /entrypoint.sh

# SteamCMD's self-update, done once here instead of on every container start: 14 s cold
# against 2 s warm (measured 2026-09-27), and the weekly rebuild keeps it current.
# The Wine prefix is NOT baked in: Wine 10 copies its DLLs into it, 1.4 GB on every node's pull
# to save the 19 s the supervisor spends creating it on a container's first start.
RUN steamcmd +quit >/dev/null 2>&1; test -d /root/.local/share/Steam

# Wine's own debug channels are noise in the app log (every missing window driver, every
# unimplemented call); the game's log is what is worth reading.
ENV WINEDEBUG=-all \
    FLUX_IMAGE_VERSION=${FLUX_IMAGE_VERSION} \
    FLUX_WINE_VERSION=${WINE_VERSION}

VOLUME ["/mnt/vrising/server", "/mnt/vrising/persistentdata"]

# A first start downloads about 2 GB and generates the Wine prefix, so the grace is generous.
# FluxOS does not act on health; this is for anyone running the image by hand.
HEALTHCHECK --interval=60s --timeout=10s --start-period=20m --retries=3 \
    CMD pgrep -f VRisingServer.exe >/dev/null || exit 1

CMD ["/opt/flux/flux-entrypoint.sh"]
