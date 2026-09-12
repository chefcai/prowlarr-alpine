# prowlarr-alpine — minimal Prowlarr (.NET 8 self-contained) image on Alpine.
#
# Pattern mirrors chefcai/sonarr-alpine, chefcai/jellyfin-alpine, chefcai/bazarr-alpine:
# - Build runs in GitHub Actions, not on the deploying host.
# - Final image is plain alpine + only the runtime artifacts needed to launch Prowlarr.
#
# Prowlarr specifics:
# - Targets net8.0 (bumped in v2.0.5.5160; confirmed in Prowlarr.runtimeconfig.json).
# - Alpine's apk does not ship dotnet8-runtime, so we use Prowlarr's
#   SELF-CONTAINED linux-musl-core-x64 tarball from prowlarr.servarr.com.
#   That tarball bundles its own .NET 8 runtime (libcoreclr.so, libclrjit.so,
#   libhostfxr.so, etc.) alongside Prowlarr.dll — the base image only needs:
#     icu-libs      (CoreCLR globalization native; Prowlarr uses culture-aware
#                    string comparisons for indexer matching/sorting)
#     sqlite-libs   (native libsqlite3 — libe_sqlite3.so in the tarball P/Invokes
#                    the system sqlite3; Prowlarr 2.3.5 added a fallback but the
#                    system lib is still needed)
#     tzdata        (TZ env support; defaults to UTC, override via the TZ env var)
#     ca-certificates (HTTPS to indexers and Prowlarr's update-check endpoint)
#
# Compared to upstream linuxserver/prowlarr the savings come from:
# - Dropping ghcr.io/linuxserver/baseimage-alpine and its s6-overlay, bash, jq,
#   curl, procps-ng, shadow, xmlstarlet, docker-mods (~8-10 MB compressed).
# - Pruning Prowlarr.Update (~81 MB uncompressed / ~8 MB compressed — gzip
#   deduplicates heavily against the parent's runtime DLLs but there's still
#   meaningful delta from the update-specific managed assemblies).
# - Removing *.pdb debug symbols, UI/*.map source-maps, ServiceInstall/
#   ServiceUninstall (Windows-only ELF service installers), and createdump
#   (diagnostic dump utility, not needed in Docker).

ARG PROWLARR_VERSION=2.3.5.5327
ARG PROWLARR_BRANCH=master

# ---- Stage 1: fetch & unpack -----------------------------------------------
FROM alpine:3.21 AS fetch
ARG PROWLARR_VERSION
ARG PROWLARR_BRANCH
RUN apk add --no-cache curl tar
WORKDIR /work

# prowlarr.servarr.com is the canonical update endpoint (same one LSIO uses).
# The linuxmusl variant is the self-contained build for musl-libc (Alpine).
RUN curl -fsSL \
    "https://prowlarr.servarr.com/v1/update/${PROWLARR_BRANCH}/updatefile?version=${PROWLARR_VERSION}&os=linuxmusl&runtime=netcore&arch=x64" \
    -o /work/prowlarr.tar.gz \
  && mkdir -p /work/prowlarr \
  && tar xzf /work/prowlarr.tar.gz -C /work/prowlarr --strip-components=1 \
  && rm /work/prowlarr.tar.gz

# Prune — every byte counts on storage-constrained hosts.
#
# SAFE prunes (verified class from sonarr-alpine + Prowlarr-specific inspection):
# - Prowlarr.Update (~81 MB uncompressed): in-app updater bundling its own .NET
#   runtime. We update via `docker pull`. LSIO also removes this.
# - *.pdb: .NET debug symbols. Stack traces still resolve method names (just not
#   line numbers). Prowlarr has 11 pdb files in the v2.3.5 tarball.
# - UI/*.map (3 files, ~10.5 MB uncompressed): SPA source maps used only by
#   browser dev-tools to debug minified JS. Prowlarr UI still works without them.
# - ServiceInstall/ServiceUninstall (74 KB each): Windows service-installer ELF
#   stubs. Not referenced by Prowlarr.deps.json on Linux.
# - createdump (108 KB): .NET diagnostic core-dump utility. Not needed in Docker.
#
# DO NOT prune (lessons from sonarr-alpine — same .NET framework, same SIGSEGV
# risk for any DLL that appears Windows-only but is transitively resolved at
# startup by libcoreclr/libhostfxr):
# - Microsoft.Win32.Registry.dll, SystemEvents.dll
# - Microsoft.AspNetCore.Server.HttpSys.dll, IIS*.dll
# - Microsoft.VisualBasic*.dll, WindowsBase.dll, System.Windows*.dll
# - System.ServiceProcess*.dll, System.Diagnostics.EventLog.dll
# - Microsoft.Data.SqlClient.dll, Microsoft.Extensions.Hosting.WindowsServices.dll
# - Microsoft.Extensions.Logging.EventLog.dll
RUN set -eux; \
    cd /work/prowlarr; \
    rm -rf Prowlarr.Update; \
    find . -name '*.pdb' -type f -delete; \
    rm -f UI/*.map; \
    rm -f ServiceInstall ServiceUninstall; \
    rm -f createdump

# Write package_info so Prowlarr knows it's docker-managed and won't attempt
# self-update (which would try to re-download Prowlarr.Update).
ARG PROWLARR_VERSION
ARG PROWLARR_BRANCH
RUN printf 'UpdateMethod=docker\nBranch=%s\nPackageVersion=%s\nPackageAuthor=[chefcai/prowlarr-alpine](https://github.com/chefcai/prowlarr-alpine)\n' \
    "${PROWLARR_BRANCH}" "${PROWLARR_VERSION}" \
    > /work/prowlarr/package_info

# ---- Stage 2: runtime -------------------------------------------------------
FROM alpine:3.21
ARG PROWLARR_VERSION
LABEL org.opencontainers.image.title="prowlarr-alpine"
LABEL org.opencontainers.image.description="Footprint-minimized Prowlarr image on Alpine. See https://github.com/chefcai/prowlarr-alpine"
LABEL org.opencontainers.image.source="https://github.com/chefcai/prowlarr-alpine"
LABEL org.opencontainers.image.licenses="GPL-3.0-only"
LABEL org.opencontainers.image.version="${PROWLARR_VERSION}"

# COMPlus_EnableDiagnostics=0: disable .NET diagnostics (no perf counters/EventPipe
#   sockets) — saves a bit of RAM and matches what LSIO sets.
# XDG_CONFIG_HOME: Prowlarr honours XDG; point it inside /config so the bind mount
#   captures everything.
# TMPDIR: Prowlarr (and underlying .NET) write temp files here. LSIO uses
#   /run/prowlarr-temp; we match that to avoid surprises if config is shared.
# TZ: default; overridden at runtime by the compose TZ env var.
ENV COMPlus_EnableDiagnostics=0 \
    XDG_CONFIG_HOME=/config/xdg \
    TMPDIR=/run/prowlarr-temp \
    TZ=UTC

# Runtime deps:
#   icu-libs      — .NET 8 globalization. Without it, .NET throws
#                   System.Globalization.CultureNotFoundException unless
#                   DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1. Prowlarr uses
#                   culture-aware comparisons; invariant mode is not safe.
#   sqlite-libs   — native libsqlite3.so; libe_sqlite3.so in the tarball
#                   P/Invokes it as a fallback/system lib.
#   tzdata        — /usr/share/zoneinfo so TZ=America/New_York works.
#   ca-certificates — outbound HTTPS to indexers, servarr.com update checks, etc.
#
# UID/GID 13001:13000 — homelab convention, matches sonarr/radarr/jellyfin/seerr.
# Fixed at build time so config-dir bind mounts owned 13001:13000 just work.
RUN apk add --no-cache \
        icu-libs \
        sqlite-libs \
        tzdata \
        ca-certificates \
        su-exec \
    && addgroup -g 13000 prowlarr \
    && adduser -D -u 13001 -G prowlarr -h /config -s /sbin/nologin prowlarr \
    && mkdir -p /config /app /run/prowlarr-temp \
    && chown -R prowlarr:prowlarr /config /app /run/prowlarr-temp

COPY --from=fetch --chown=prowlarr:prowlarr /work/prowlarr /app/prowlarr/bin

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# NOTE: intentionally stays as root here -- entrypoint.sh drops to
# PUID:PGID (default 1000:1000) via su-exec at container start. See
# https://github.com/chefcai/prowlarr-alpine/issues/1
WORKDIR /app/prowlarr/bin
EXPOSE 9696

# Healthcheck uses busybox wget — no curl in the image.
# /ping is a Servarr-framework endpoint (all *arr apps have it); returns
# {"status":"OK"} with HTTP 200 once Prowlarr is fully started.
HEALTHCHECK --interval=1m30s --timeout=10s --retries=3 --start-period=60s \
    CMD wget --no-verbose --tries=1 --spider http://localhost:9696/ping || exit 1

# Prowlarr's self-contained AppHost launches the .NET 8 runtime.
# --data  : per-instance config dir (SQLite DB, indexer configs, logs).
# --nobrowser: suppresses the "open browser on startup" behaviour; no-op
#              in Docker but signals intent.
ENTRYPOINT ["/entrypoint.sh"]
CMD ["./Prowlarr", "--data=/config", "--nobrowser"]
