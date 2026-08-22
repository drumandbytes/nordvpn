# nordvpn

[![Build](https://github.com/drumandbytes/nordvpn/actions/workflows/build.yml/badge.svg)](https://github.com/drumandbytes/nordvpn/actions/workflows/build.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A minimal, actively-rebuilt container image for the official [NordVPN](https://nordvpn.com/) Linux client — installed fresh from `repo.nordvpn.com`'s apt repo on every build, no systemd required. Works as a regular VPN tunnel sidecar, a [Meshnet](https://meshnet.nordvpn.com/) node, or both at once — nothing is enabled unless you ask for it.

## Why this exists

The existing community images ([`bubuntux/nordvpn`](https://github.com/bubuntux/nordvpn), [`MattsTechInfo/Meshnet`](https://github.com/MattsTechInfo/Meshnet), [`DPflasterer/nordvpn-meshnet`](https://github.com/DPflasterer/nordvpn-meshnet)) are all 2-4 years stale. There's nothing complex to them — install the official `nordvpn` package, run `nordvpnd` in the foreground instead of under systemd, drive it with the CLI — so this image just does that, and a weekly GitHub Actions build keeps it tracking whatever's current in NordVPN's `stable` apt channel.

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
        command: ["/healthcheck.sh"]
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

## GHCR package visibility

New GHCR packages default to private even in a public repo. If pulls fail with an auth error, flip it once: this repo's Packages sidebar → package settings → Change visibility → Public.

## License

MIT — see [LICENSE](LICENSE). Not affiliated with or endorsed by Nord Security.
