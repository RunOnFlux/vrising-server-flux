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
# Wine 10.0 staging-tkg from Kron4ek/Wine-Builds, for its fsync (2026-10-16). Upstream Wine
# (WineHQ's, which this image ran until then) sends every thread wait of a Windows server through
# wineserver; fsync does those waits on futexes in the game's own process. For Enshrouded that
# was half its CPU (same move, enshrouded-server-flux 96761c4). V Rising barely waits on
# wineserver, so its gain is small: idle on 4 vCPU, 0.19-0.21 -> 0.15-0.19 cores.
# Still 10.0, the version this server and its BepInEx mods were verified on. PINNED by version
# AND checksum: an unpinned build on 2026-09-26 pulled 11.0, which drops the wine64 launcher the
# server was started with, and every start failed with 127. TKG builds from 10.16 on (and WineHQ
# 11) are ntsync-only, which needs /dev/ntsync, a device Flux cannot pass into a container.
# The wow64 build is 64-bit only (the server is too); i386 stays for SteamCMD alone.
# Moving Wine is a deliberate change, tested on a real server, never a side effect of a rebuild.
ARG WINE_VERSION=10.0
ARG WINE_TKG_SHA256=fe9b45a6ac181c7fe6290ea83e3a6d4abb8ca08d79236ffd95ede5413a9faa80

# The libraries Wine loads for a headless server under Xvfb (X11, fonts, TLS, Kerberos for
# winbind), out of what WineHQ's wine-stable-amd64 depends on and recommends; audio, scanners,
# cameras, printing and GStreamer are left out.
RUN echo steam steam/question select "I AGREE" | debconf-set-selections && \
    echo steam steam/license note '' | debconf-set-selections && \
    apt-get update -y && \
    apt-get upgrade -y --no-install-recommends && \
    apt-get install -y --no-install-recommends ca-certificates wget xz-utils software-properties-common && \
    add-apt-repository -y multiverse && \
    dpkg --add-architecture i386 && \
    apt-get update -y && \
    apt-get install -y --no-install-recommends \
        libx11-6 libxext6 libxrender1 libxi6 libxrandr2 libxcursor1 libxcomposite1 libxfixes3 \
        libxinerama1 libxxf86vm1 libxkbcommon0 libgl1 libglu1-mesa libfreetype6 libfontconfig1 \
        libgnutls30 libunwind8 libudev1 libdbus-1-3 libkrb5-3 libgssapi-krb5-2 libpng16-16 \
        steamcmd winbind xvfb tzdata procps python3-minimal && \
    pkg="wine-${WINE_VERSION}-staging-tkg-amd64-wow64" && \
    wget -qO "/tmp/${pkg}.tar.xz" \
      "https://github.com/Kron4ek/Wine-Builds/releases/download/${WINE_VERSION}/${pkg}.tar.xz" && \
    echo "${WINE_TKG_SHA256}  /tmp/${pkg}.tar.xz" | sha256sum -c - && \
    tar -xJf "/tmp/${pkg}.tar.xz" -C /opt && mv "/opt/${pkg}" /opt/wine && rm "/tmp/${pkg}.tar.xz" && \
    test -x /opt/wine/bin/wine64 && \
    apt-get remove -y --purge wget xz-utils software-properties-common && \
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
# WINEFSYNC needs futex_waitv (Linux 5.16+, allowed by Docker's default seccomp profile); where
# it is missing Wine falls back to esync (eventfd), and only then to wineserver. Proof that it is
# on: a /dev/shm/wine-*-fsync file in the container (Wine's own output goes to /dev/null).
ENV PATH=/opt/wine/bin:${PATH} \
    WINEFSYNC=1 \
    WINEESYNC=1 \
    WINEDEBUG=-all \
    FLUX_IMAGE_VERSION=${FLUX_IMAGE_VERSION} \
    FLUX_WINE_VERSION=${WINE_VERSION}

VOLUME ["/mnt/vrising/server", "/mnt/vrising/persistentdata"]

# A first start downloads about 2 GB and generates the Wine prefix, so the grace is generous.
# FluxOS does not act on health; this is for anyone running the image by hand.
HEALTHCHECK --interval=60s --timeout=10s --start-period=20m --retries=3 \
    CMD pgrep -f VRisingServer.exe >/dev/null || exit 1

CMD ["/opt/flux/flux-entrypoint.sh"]
