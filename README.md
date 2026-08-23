# nordvpn

[![Build](https://github.com/drumandbytes/nordvpn/actions/workflows/build.yml/badge.svg)](https://github.com/drumandbytes/nordvpn/actions/workflows/build.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A minimal, actively-rebuilt container image for the official [NordVPN](https://nordvpn.com/) Linux client — installed fresh from `repo.nordvpn.com`'s apt repo on every build, shipped on [distroless](https://github.com/GoogleContainerTools/distroless) with no shell, no package manager, and no systemd. Works as a regular VPN tunnel sidecar, a [Meshnet](https://meshnet.nordvpn.com/) node, or both at once — nothing is enabled unless you ask for it.

## Why this exists

The existing community images ([`bubuntux/nordvpn`](https://github.com/bubuntux/nordvpn), [`MattsTechInfo/Meshnet`](https://github.com/MattsTechInfo/Meshnet), [`DPflasterer/nordvpn-meshnet`](https://github.com/DPflasterer/nordvpn-meshnet)) are all 2-4 years stale. There's nothing complex to the client itself — install the official `nordvpn` package, run `nordvpnd` in the foreground instead of under systemd, drive it with the CLI — so this image just does that, and a weekly GitHub Actions build keeps it tracking whatever's current in NordVPN's `stable` apt channel.

## How it's built

Three-stage `Dockerfile`:

1. **`deb-builder`** (`debian:trixie-slim`) — installs the real `nordvpn` package plus `iptables`/`iproute2`/`wireguard-tools`/`nftables`/`procps` via apt. Each of the latter two packages was added after something `nordvpnd` shells out to by bare name (PATH lookup) turned out to be missing — `nft` for firewall/routing setup during `connect`, `sysctl` for interface tuning, `ps` for norduserd's own process check — invisible until that specific code path was actually exercised.
2. **`go-builder`** — compiles a small Go binary (`main.go`) that replaces the old shell `entrypoint.sh`/`healthcheck.sh`. Distroless has no shell at all, so the entrypoint has to be a real binary.
3. **Final stage** — `gcr.io/distroless/base-debian13`: no apt, no shell, no package manager. Just the specific binaries and shared libraries this needs, `COPY`'d in explicitly from `deb-builder` (the exact file list came from inspecting the real package with `dpkg -L nordvpn` and each binary's actual dependency graph with `ldd` — not guessed), plus the compiled entrypoint from `go-builder`.

Net effect: ~40% smaller image, and a meaningfully smaller CVE surface than the full Debian image, since most of Debian's own userland (and its steady stream of base-package CVEs) never makes it into the final image at all.

The Go entrypoint also does one thing the old shell version didn't: since it's PID 1, it reaps any child process `nordvpnd` spawns and abandons (`nordfileshare`, `norduserd`, `openvpn`) instead of letting them accumulate as zombies, and forwards `SIGTERM`/`SIGINT` to `nordvpnd` properly.

## Usage

### Regular VPN tunnel (e.g. as a torrent client's network)

```sh
docker run -d \
  --cap-add=NET_ADMIN --cap-add=NET_RAW \
  --device=/dev/net/tun \
  -e NORDVPN_TOKEN=<your access token> \
  -e NORDVPN_CONNECT=Netherlands \
  ghcr.io/drumandbytes/nordvpn:latest
```

Other containers attach to its network namespace, same as any VPN sidecar:

```sh
docker run -it --net=container:<this container's name> -d your/other-image
```

### Meshnet node

```sh
docker run -d \
  --cap-add=NET_ADMIN --cap-add=NET_RAW \
  --device=/dev/net/tun \
  -e NORDVPN_TOKEN=<your access token> \
  -e NORDVPN_MESHNET=on \
  -e NORDVPN_NICKNAME=my-device \
  ghcr.io/drumandbytes/nordvpn:latest
```

Generate an access token: NordVPN account → Meshnet (or VPN) → Manual setup → Access token.

### Environment variables

| Variable | Description |
|----------|--------------|
| `NORDVPN_TOKEN` | Access token used to log in. Required unless a session is already persisted in a mounted `/var/lib/nordvpn`. |
| `NORDVPN_CONNECT` | Connects to a VPN server. Empty value = recommended server; otherwise a country/city/server/group, anything `nordvpn connect` itself accepts. Unset by default (no VPN tunnel). |
| `NORDVPN_MESHNET` | `on` to enable Meshnet. Unset/anything else = off. |
| `NORDVPN_NICKNAME` | Sets this device's Meshnet nickname (`nordvpn meshnet set nickname`). Only applies when `NORDVPN_MESHNET=on`. Without one, every restart can show up as a new device unless state is persisted. |
| `NORDVPN_FIREWALL` | `on` or `off`. Unset by default — leaves the client's own default behavior alone. If you're using `NORDVPN_MESHNET=on` **without** `NORDVPN_CONNECT` (Meshnet only, no VPN exit server), you probably want this set to `off` explicitly, since the killswitch otherwise blocks the container's normal non-tunnel traffic. |
| `NORDVPN_LOG_LEVEL` | `debug`, `info` (default), `warn`, or `error`. `nordvpnd` defaults to its most verbose (`debug`) when it can't find a log-level file to read, which is always true on a fresh container — this just writes one before starting the daemon. |

### Persisting device/session identity

Mount a volume at `/var/lib/nordvpn` to keep the same login and Meshnet device (and any peer permissions granted to it) across container restarts.

### Kubernetes

```yaml
containers:
  - name: nordvpn
    image: ghcr.io/drumandbytes/nordvpn:latest
    securityContext:
      capabilities:
        add: ["NET_ADMIN", "NET_RAW"]
    env:
      - name: NORDVPN_TOKEN
        valueFrom:
          secretKeyRef:
            name: nordvpn-token
            key: token
      - name: NORDVPN_MESHNET
        value: "on"
      - name: NORDVPN_FIREWALL
        value: "off"
    volumeMounts:
      - name: dev-net-tun
        mountPath: /dev/net/tun
      - name: nordvpn-state
        mountPath: /var/lib/nordvpn
    livenessProbe:
      exec:
        command: ["/entrypoint", "healthcheck"]
      initialDelaySeconds: 30
      periodSeconds: 30
volumes:
  - name: dev-net-tun
    hostPath:
      path: /dev/net/tun
  - name: nordvpn-state
    persistentVolumeClaim:
      claimName: nordvpn-state
```

Put other containers in the same Pod spec to share this one's network — containers in a Pod share a network namespace natively, no extra config needed.

The host kernel needs iptables/netfilter modules available — the NordVPN client uses `iptables` internally to route and firewall its traffic.

**Meshnet specifically needs more than `NET_ADMIN`/`NET_RAW`.** Its routing setup writes `net.ipv4.conf.all.rp_filter`, which stays read-only under Kubernetes/Docker regardless of those capabilities — confirmed directly, including that Docker's own `--sysctl` flag only sets the *initial* value, not ongoing write access. Nothing short of `securityContext.privileged: true` unlocks it. A plain VPN tunnel (`NORDVPN_CONNECT` without `NORDVPN_MESHNET`) doesn't hit this and works fine with just the two capabilities above.

### Extracting the WireGuard key (e.g. for gluetun)

NordLynx is WireGuard underneath, so once connected the private key and assigned address are readable with `wg` (included in this image):

```sh
docker run -d --name nordvpn-keygen \
  --cap-add=NET_ADMIN --cap-add=NET_RAW --device=/dev/net/tun \
  -e NORDVPN_TOKEN=<your access token> -e NORDVPN_CONNECT= \
  ghcr.io/drumandbytes/nordvpn:latest
docker exec nordvpn-keygen wg show nordlynx private-key
docker exec nordvpn-keygen ip -4 addr show nordlynx   # the /32 address to pair with it
docker rm -f nordvpn-keygen
```

## Building locally

```sh
docker build -t nordvpn .
```

## License

MIT — see [LICENSE](LICENSE). Not affiliated with or endorsed by Nord Security.
