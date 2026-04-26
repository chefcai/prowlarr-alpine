# prowlarr-alpine

Footprint-minimized [Prowlarr](https://github.com/Prowlarr/Prowlarr) Docker image on Alpine Linux.

Part of the [chefcai](https://github.com/chefcai) custom-image family for squirttle's 12 GB eMMC homelab:
`jellyfin-alpine` · `seerr-alpine` · `bazarr-alpine` · `sonarr-alpine` · **`prowlarr-alpine`**

---

## Sizes (linux/amd64)

| Iteration | Base | Compressed | On-disk | vs upstream |
|---|---|---:|---:|---:|
| iter-0 | `lscr.io/linuxserver/prowlarr:latest` (baseline) | **78.3 MB** | 193 MB | — |
| iter-1 | alpine:3.21 + musl tarball + safe prune | TBD | TBD | TBD |
| iter-2 | debian:bookworm-slim + glibc tarball | TBD | TBD | TBD |
| iter-3 | gcr.io/distroless/cc-debian12 + glibc tarball | TBD | TBD | TBD |

> **30 % target:** ≤ 54.8 MB compressed. Based on the sonarr-alpine experience
> (−15.5 % achievable, 30 % not, due to the self-contained .NET floor), this
> target is ambitious. The iteration log below documents every attempt.

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
which layers in s6-overlay, bash, jq, curl, xmlstarlet, procps-ng, shadow,
docker-mods infrastructure. None of that is needed to run Prowlarr.

Our image:
1. **Plain `alpine:3.21`** runtime with four APKs: `icu-libs`, `sqlite-libs`,
   `tzdata`, `ca-certificates`.
2. **Prowlarr self-contained `.NET 8` tarball** from `prowlarr.servarr.com`
   (same source LSIO uses).
3. **Pruned** before the final COPY:
   - `Prowlarr.Update/` (~81 MB uncompressed) — we update via `docker pull`
   - `*.pdb` debug symbols (11 files)
   - `UI/*.map` source-maps (3 files, ~10.5 MB uncompressed)
   - `ServiceInstall`, `ServiceUninstall` (Windows-only ELF stubs)
   - `createdump` (diagnostic utility)

---

## Iteration log

### iter-0 — upstream baseline

- **Image:** `lscr.io/linuxserver/prowlarr:latest`
- **Compressed (linux/amd64):** 78.3 MB (9 layers)
- **On-disk:** 193 MB
- **Notes:** Measured 2026-04-26 at version 2.3.5.5327.

### iter-1 — Alpine + musl + safe prune ✅ **(current `:latest`)**

> *Results will be filled in after the first GitHub Actions build completes.*

- **Dockerfile:** `Dockerfile` (alpine:3.21 + linux-musl-core-x64 tarball)
- **Prune:** Prowlarr.Update, *.pdb, UI/*.map, ServiceInstall, ServiceUninstall, createdump
- **Compressed:** TBD
- **On-disk:** TBD
- **vs iter-0:** TBD

### iter-2 — debian:bookworm-slim + glibc

> *Comparison variant. Expected to be LARGER than Alpine based on sonarr-alpine
> experience (+30 % for debian vs alpine).*

- **Dockerfile:** `Dockerfile.debian`
- **Compressed:** TBD
- **vs iter-0:** TBD (expected +25-35 %)

### iter-3 — distroless/cc-debian12 + glibc

> *Comparison variant. Expected slightly smaller than bookworm-slim but larger
> than Alpine. Not suitable for production (no healthcheck, UID constraints).*

- **Dockerfile:** `Dockerfile.distroless`
- **Compressed:** TBD
- **vs iter-0:** TBD

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

---

## Build pipeline

- Push to `main` / `workflow_dispatch` / daily cron at **07:30 UTC**
- Daily cron skips if upstream master version already published
- `concurrency: build-${{ github.ref }}, cancel-in-progress: true`
- `workflow_dispatch` inputs: `dockerfile` (variant selector), `tag_suffix`
  (iteration builds don't overwrite `:latest`), `measure_baseline` (iter-0)
- Per-variant BuildKit cache scope (no cross-variant poisoning)

---

## Safe vs unsafe prunes

### Safe (applied in iter-1)

| Item | Uncompressed | Reason safe |
|---|---:|---|
| `Prowlarr.Update/` | ~81 MB | In-app updater; updates via docker pull instead |
| `*.pdb` | ~4 MB | Debug symbols; stack traces still resolve method names |
| `UI/*.map` | ~10.5 MB | SPA source maps; only useful in browser dev-tools |
| `ServiceInstall`, `ServiceUninstall` | ~145 KB | Windows service ELF stubs; not in deps.json |
| `createdump` | ~108 KB | .NET core-dump utility; not needed in Docker |

### Do NOT prune (SIGSEGV risk — lesson from sonarr-alpine)

The Servarr framework's `.deps.json` files (or transitive Microsoft.AspNetCore.App /
Microsoft.NETCore.App manifest entries) reference these DLLs at load time even on
Linux. When `libcoreclr`/`libhostfxr` fails to resolve them it crashes with exit 139
(SIGSEGV) and no stdout. They look Windows-only by name but are not:

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
  image: ghcr.io/chefcai/prowlarr-alpine:latest
  init: true
  container_name: prowlarr
  logging:
    driver: json-file
    options:
      max-size: "10m"
      max-file: "3"
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
  networks:
    - arrs_net
```

After switching:
```bash
docker compose -f ~/arrs/docker-compose.yml up -d prowlarr
docker image prune -f   # reclaim space from the LSIO image
```
