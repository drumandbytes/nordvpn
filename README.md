# nordvpn-meshnet

[![Build](https://github.com/drumandbytes/nordvpn-meshnet/actions/workflows/build.yml/badge.svg)](https://github.com/drumandbytes/nordvpn-meshnet/actions/workflows/build.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A minimal, actively-rebuilt container image for [NordVPN Meshnet](https://meshnet.nordvpn.com/) — the official Linux client, installed fresh from `repo.nordvpn.com`'s apt repo on every build, with no systemd required.

## Why this exists

The existing community images ([`bubuntux/nordvpn`](https://github.com/bubuntux/nordvpn), [`MattsTechInfo/Meshnet`](https://github.com/MattsTechInfo/Meshnet), [`DPflasterer/nordvpn-meshnet`](https://github.com/DPflasterer/nordvpn-meshnet)) are all 2-4 years stale. There's nothing complex to them — install the official `nordvpn` package, run `nordvpnd` in the foreground instead of under systemd, drive it with the CLI — so this image just does that, and a weekly GitHub Actions build keeps it tracking whatever's current in NordVPN's `stable` apt channel.

## Usage

```sh
docker run -d \
  --cap-add=NET_ADMIN --cap-add=NET_RAW \
  --device=/dev/net/tun \
  -e NORDVPN_TOKEN=<your access token> \
  -e NORDVPN_NICKNAME=my-device \
  ghcr.io/drumandbytes/nordvpn-meshnet:latest
```

Generate an access token: NordVPN account → Meshnet → Manual setup → Access token.

### Sharing the tunnel with another container

Same pattern as any VPN sidecar — start this image first, then attach other containers to its network namespace:

```sh
docker run -it --net=container:meshnet -d your/other-image
```

Or in Kubernetes, put both containers in the same Pod spec — they share the network namespace natively.

### Environment variables

| Variable | Description |
|----------|--------------|
| `NORDVPN_TOKEN` | Access token used to log in. Required unless a session is already persisted in a mounted `/var/lib/nordvpn`. |
| `NORDVPN_NICKNAME` | Sets this device's Meshnet nickname (`nordvpn meshnet set nickname`). Without one, every restart can show up as a new device unless state is persisted. |
| `NORDVPN_FIREWALL` | `on` or `off` (default `off`). This image doesn't call `nordvpn connect` — it only enables Meshnet, it doesn't route all container egress through a VPN exit server — so the killswitch is off by default to avoid blocking normal traffic. Set `on` if you know you want it. |

### Persisting device identity

Mount a volume at `/var/lib/nordvpn` to keep the same Meshnet device (and any peer permissions granted to it) across container restarts.

### Kubernetes

```yaml
containers:
  - name: nordvpn-meshnet
    image: ghcr.io/drumandbytes/nordvpn-meshnet:latest
    securityContext:
      capabilities:
        add: ["NET_ADMIN", "NET_RAW"]
    env:
      - name: NORDVPN_TOKEN
        valueFrom:
          secretKeyRef:
            name: nordvpn-token
            key: token
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

The host kernel needs iptables/netfilter modules available — the NordVPN client uses `iptables` internally to route and firewall its traffic.

## Building locally

```sh
docker build -t nordvpn-meshnet .
```

## License

MIT — see [LICENSE](LICENSE). Not affiliated with or endorsed by Nord Security.
