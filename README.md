# prowlarr-alpine

Footprint-minimized [Prowlarr](https://github.com/Prowlarr/Prowlarr) Docker image on Alpine Linux.

Part of the [chefcai](https://github.com/chefcai) custom-image family for squirttle's 12 GB eMMC homelab:
`jellyfin-alpine` · `seerr-alpine` · `bazarr-alpine` · `sonarr-alpine` · **`prowlarr-alpine`**

---

## Sizes (linux/amd64)

| Iteration | Base | Compressed | On-disk | vs upstream |
|---|---|---:|---:|---:|
| iter-0 | `lscr.io/linuxserver/prowlarr:latest` (baseline) | 78.3 MB | 193 MB | — |
| **iter-1 ✅** | **alpine:3.21 + musl tarball + safe prune** | **65.4 MB** | **158 MB** | **−16.5% / −18.1%** |
| iter-2 ❌ | debian:bookworm-slim + glibc tarball | 102.6 MB | — | +31.1% |
| iter-3 ❌ | gcr.io/distroless/cc-debian12 + glibc | 81.4 MB | — | +4.0% |

> **30 % target:** ≤ 54.8 MB compressed. **Not achievable.** The binding constraint is
> Prowlarr's self-contained .NET 8 tarball (~98 MB compressed, pulled from
> `prowlarr.servarr.com`). That floor is set by the Prowlarr release pipeline — we don't
> control it. The −16.5 % achieved is the practical maximum while keeping Prowlarr
> functional. Same conclusion as `sonarr-alpine` (−15.5 %) and expected for any
> Servarr-family app on .NET self-contained.

---

## Quick start

```yaml
prowlarr:
  image: ghcr.io/chefcai/prowlarr-alpine:latest
  init: true
  container_name: prowlarr
  environment:
    - TZ=America/New_York
  healthcheck:
    test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:9696/ping"]
    interval: 1m30s
    timeout: 10s
    retries: 3
  ports:
    - "9696:9696"
  volumes:
    - /home/haadmin/config/prowlarr-config:/config
    - /mnt/Media/config/prowlarr/Backups:/config/Backups
    - /mnt/Media/config/prowlarr/logs:/config/logs
  restart: unless-stopped
```

Key differences from the `linuxserver/prowlarr` block:
- `init: true` — no s6-overlay; Docker provides PID 1
- Drop `PUID` / `PGID` / `UMASK` env vars — UID 13001 / GID 13000 baked in
- Healthcheck uses `wget` (busybox, no curl in image) against `/ping` (no URL-base prefix)

---

## Why smaller?

Upstream `linuxserver/prowlarr` is built on `ghcr.io/linuxserver/baseimage-alpine`
which layers in s6-overlay, bash, jq, curl, xmlstarlet, procps-ng, shadow, and
docker-mods infrastructure. None of that is needed to run Prowlarr.

Our image:
1. **Plain `alpine:3.21`** runtime with four APKs: `icu-libs`, `sqlite-libs`,
   `tzdata`, `ca-certificates`.
2. **Prowlarr self-contained `.NET 8` tarball** from `prowlarr.servarr.com`
   (same source LSIO uses, `linux-musl-core-x64` variant).
3. **Pruned** before the final COPY:
   - `Prowlarr.Update/` (~81 MB uncompressed) — we update via `docker pull`
   - `*.pdb` debug symbols (11 files, ~4 MB)
   - `UI/*.map` source-maps (3 files, ~10.5 MB uncompressed)
   - `ServiceInstall`, `ServiceUninstall` (Windows-only ELF stubs, ~145 KB)
   - `createdump` (diagnostic utility, ~108 KB)

---

## Iteration log

### iter-0 — upstream baseline

- **Image:** `lscr.io/linuxserver/prowlarr:latest`
- **Compressed (linux/amd64):** 78.3 MB (9 layers)
- **On-disk:** 193 MB
- **Notes:** Measured 2026-04-26 at Prowlarr version 2.3.5.5327. LSIO uses
  `baseimage-alpine:3.23` with s6-overlay + curl + xmlstarlet + runtime overhead.

### iter-1 — Alpine + musl + safe prune ✅ **(current `:latest`)**

- **Dockerfile:** `Dockerfile` (alpine:3.21 + linux-musl-core-x64 tarball)
- **Prune:** Prowlarr.Update, *.pdb (11 files), UI/*.map (3 files), ServiceInstall,
  ServiceUninstall, createdump
- **APKs:** `icu-libs`, `sqlite-libs`, `tzdata`, `ca-certificates`
- **Compressed:** **65.4 MB** (4 layers)
- **On-disk:** **158 MB**
- **vs iter-0:** **−16.5 % compressed, −18.1 % on-disk** ✅
- **Deployed:** 2026-04-26 on squirttle. Smoke-tested: `/ping` returns `{"status":"OK"}`,
  container healthy in 40 s, 192.6 MB freed by removing LSIO image.

### iter-2 — debian:bookworm-slim + glibc ❌

- **Dockerfile:** `Dockerfile.debian`
- **Tarball:** `linux-core-x64` (glibc build)
- **APTs:** `libicu72`, `libsqlite3-0`, `tzdata`, `ca-certificates`, `wget`
- **Compressed:** 102.6 MB (4 layers) — **+31.1 %** vs upstream
- **Notes:** Same outcome as `sonarr-alpine` iter-2. The debian:bookworm-slim base
  is ~29 MB compressed vs Alpine's ~3 MB, and the glibc .NET tarball is slightly
  larger than the musl one. Both effects compound. **Do not use.**
- **Bug fixed during iteration:** `ENV TMPDIR=/run/prowlarr-temp` is inherited by
  `apt-get install ca-certificates`'s post-install script which calls `mktemp`. If the
  directory doesn't exist yet, dpkg exits 100. Fix: `mkdir -p /run/prowlarr-temp`
  as the first command in the runtime-stage RUN.

### iter-3 — gcr.io/distroless/cc-debian12 + glibc ❌

- **Dockerfile:** `Dockerfile.distroless`
- **Base:** distroless/cc-debian12 (glibc + libstdc++ only)
- **Extra libs copied:** `libicudata.so.72`, `libicui18n.so.72`, `libicuuc.so.72`,
  `libsqlite3.so.0`, tzdata, ca-certificates — all from a `debian:bookworm-slim` helper stage
- **Compressed:** 81.4 MB (29 layers — one COPY per lib file)
- **vs iter-0:** **+4.0 %** — worse than upstream
- **Notes:** distroless saves the Debian package metadata + apt tooling (~5 MB) but
  the piecemeal COPY-per-lib approach creates 29 layers and each COPY adds overhead.
  The glibc tarball is also slightly larger than musl. Not worth pursuing.
  The variant also violates the UID 13001 requirement cleanly (uses a passwd-copy
  workaround) and has no HEALTHCHECK (distroless has no shell). **Measurement only.**

---

## Prowlarr facts

- **Version channel:** `master` (Prowlarr's stable production channel)
- **Runtime:** .NET 8 self-contained (bundled since v2.0.5.5160)
- **Port:** 9696
- **Config dir:** `/config`
- **Health endpoint:** `/ping` → `{"status":"OK"}` (HTTP 200 when fully started)
- **Tarball URL:** `prowlarr.servarr.com/v1/update/master/updatefile?version={V}&os=linuxmusl&runtime=netcore&arch=x64`
- **Required APKs (Alpine):** `icu-libs`, `sqlite-libs`, `tzdata`, `ca-certificates`
- **UID/GID:** 13001:13000 (hardcoded, matches homelab convention)
- **TMPDIR:** `/run/prowlarr-temp` (Prowlarr and Sentry write temp files here;
  created in Dockerfile and set via `ENV`)

---

## Build pipeline

- Push to `main` / `workflow_dispatch` / daily cron at **07:30 UTC**
  (staggered: bazarr 06:00 / jellyfin 06:15 / ttyd 06:30 / seerr 06:45 / sonarr 07:00 / prowlarr 07:30)
- Daily cron skips if upstream master version already published
- `concurrency: build-${{ github.ref }}, cancel-in-progress: true`
- `workflow_dispatch` inputs: `dockerfile` (variant selector), `tag_suffix`
  (iteration builds don't overwrite `:latest`), `measure_baseline` (iter-0)
- Per-variant BuildKit cache scope (no cross-variant poisoning)
- GHCR bootstrap: first push succeeded with `GITHUB_TOKEN` on public repo —
  no PAT workaround required (changed GitHub behavior vs sonarr-alpine 2026-04-25)

---

## Safe vs unsafe prunes

### Safe (applied in iter-1)

| Item | Uncompressed | Reason safe |
|---|---:|---|
| `Prowlarr.Update/` | ~81 MB | In-app updater; updates via docker pull instead |
| `*.pdb` (11 files) | ~4 MB | Debug symbols; stack traces still resolve method names |
| `UI/*.map` (3 files) | ~10.5 MB | SPA source maps; only useful in browser dev-tools |
| `ServiceInstall`, `ServiceUninstall` | ~145 KB | Windows service ELF stubs; not in deps.json on Linux |
| `createdump` | ~108 KB | .NET core-dump diagnostic tool; not needed in Docker |

### Do NOT prune (SIGSEGV risk — lesson from sonarr-alpine)

These DLLs appear Windows-only by name but are referenced in Prowlarr's `.deps.json`
(or transitively via `Microsoft.AspNetCore.App` / `Microsoft.NETCore.App` manifests).
When `libcoreclr`/`libhostfxr` fails to resolve them it crashes with exit 139 and no
stdout. Applies to all Servarr-family apps on .NET 6/8:

`Microsoft.Win32.Registry.dll` · `Microsoft.Win32.SystemEvents.dll` ·
`Microsoft.AspNetCore.Server.HttpSys.dll` · `Microsoft.AspNetCore.Server.IIS*.dll` ·
`Microsoft.VisualBasic*.dll` · `WindowsBase.dll` · `System.Windows*.dll` ·
`System.ServiceProcess*.dll` · `System.Diagnostics.EventLog.dll` ·
`Microsoft.Extensions.Hosting.WindowsServices.dll` ·
`Microsoft.Extensions.Logging.EventLog.dll` · `Microsoft.Data.SqlClient.dll`

---

## Squirttle deployment

Replace the `prowlarr` service block in `~/arrs/docker-compose.yml`:

```yaml
prowlarr:
  # Slim Alpine-based Prowlarr (65.4 MB compressed vs upstream 78.3 MB, −16.5%).
  # Source: https://github.com/chefcai/prowlarr-alpine
  image: ghcr.io/chefcai/prowlarr-alpine:latest
  #image: lscr.io/linuxserver/prowlarr:latest
  init: true   # chefcai image has no s6-overlay; Docker provides PID 1
  container_name: prowlarr
  logging:
    driver: json-file
    options:
      max-size: "10m"
      max-file: "3"
  environment:
    - TZ=America/New_York
  healthcheck:
    # prowlarr-alpine uses busybox wget (no curl); /ping has no URL-base prefix
    test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:9696/ping"]
    interval: 1m30s
    timeout: 10s
    retries: 3
  ports:
    - "9696:9696"
  volumes:
    - /home/haadmin/config/prowlarr-config:/config
    - /mnt/Media/config/prowlarr/Backups:/config/Backups
    - /mnt/Media/config/prowlarr/logs:/config/logs
  restart: unless-stopped
  networks:
    - arrs_net
```

After switching:
```bash
docker compose -f ~/arrs/docker-compose.yml up -d prowlarr
docker image rm lscr.io/linuxserver/prowlarr:latest
docker image prune -f
```
