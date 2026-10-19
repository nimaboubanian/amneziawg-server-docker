# amneziawg-server — vpndogs inbound AmneziaWG node

A userspace AmneziaWG server for the [vpndogs](https://github.com/nimaboubanian)
stack: clients connect on UDP 1063, their traffic is decrypted by
`amneziawg-go` (the obfuscated WireGuard fork — survives DPI that
fingerprints and blocks plain WireGuard) and policy-routed into a hev-socks5-tunnel
`tun`, which SOCKS-es out through the stack's router chain
(`vpndogs-router:1070`) — client traffic exits wherever the chain exits.

Use this instead of the [WireGuard sibling](../wireguard-server-docker) where
plain WireGuard is blocked/filtered; both can run at once (separate pools).

Requires AmneziaWG **3.1** protocol clients (current Amnezia app,
`awg`/`awg-quick` ≥ 3.1). Older AWG 1.x clients are not supported.

Enable with `COMPOSE_PROFILES=awg-inbound` in the stack's `.env`.

## How it works

```
client --amneziawg (obfuscated)--> host:1063/udp
                        |  (userspace daemon: amneziawg-go -f awg0)
                        v
                      policy route: from 10.10.30.0/24 lookup 200 -> tun0
                        |  (hev-socks5-tunnel tun)
                        v
                      socks://vpndogs-router:1070  -> (VPN chain exit)
```

The container runs **two** supervised daemons (AWG is a protocol fork: the
host kernel module cannot decrypt it, and no host kernel prerequisite is
needed at all — that is what makes this node more portable than the WG
sibling). `amneziawg-go -f awg0` decrypts/obfuscates; hev-socks5-tunnel provides the
tun egress. Config arrives via `awg setconf` (UAPI), address/MTU via plain
`ip` commands: `awg0.conf` (ListenPort 1063, deterministic addressing,
pinned obfuscation constants), `hev-socks5-tunnel` tun + socks chain config.

## Server-side setup

1. Pick/verify env (see `.env.example`):
   - `AWG_PEERS=name:PUBKEY,...` — **required**, BYO public keys only
   - `AWG_POOL=10.10.30.0/24` — server takes `30.1`, peer *i* takes `30.2+i`
   - `AWG_HPK=` — optional shared HeaderProtectionKey, empty = off
   - `CHAIN_SOCKS_HOST=vpndogs-router`, `CHAIN_SOCKS_PORT=1070`
2. Host prerequisites: just `/dev/net/tun` + `NET_ADMIN` (compose grants
   them) and host UDP 1063 free. **No kernel module needed.**
3. `docker compose -f deploy/compose.yaml up -d` (or via the stack compose
   with `COMPOSE_PROFILES=awg-inbound`).
4. Check the server is up: `docker compose exec vpndogs-awg-inbound report.sh`.
   The `== Server public key ==` line is what client confs copy;
   `== Obfuscation constants ==` lists the pin values clients must send.

## Object parameters and the shared key

The obfuscation constants are **fixed on this server** and must be copied
**verbatim** into every client conf:

```ini
S1 = 25
S2 = 25
S3 = 25
S4 = 25
H1 = 84
H2 = 86
H3 = 88
H4 = 90
```

`HeaderProtectionKey` symmetric: generate once (`awg genkey`), put the SAME
output into the server's `AWG_HPK` and into each client conf. Omit the line
on both sides to run without header protection. These values are the
anti-DPI knobs — if you must change them, change both sides identically.

## Client setup (BYO keys)

The server never sees a private key. On each client machine:

```sh
awg genkey | tee privatekey | awg pubkey > publickey
awg genkey > hpk.txt        # the shared HeaderProtectionKey (one value for ALL peers)
```

Then pass the **public** key as one `name:PUBKEY` entry in `AWG_PEERS`
(the name is decorative — it appears in `awg show`, handshakes, and the
rendered conf comment; it must match `^[A-Za-z0-9_@+-]+$`).

Client `awg0.conf` template:

```ini
[Interface]
Address = 10.10.30.2/32        # server takes .1; peer i (0-based) = .2+i
DNS = 1.1.1.1
PrivateKey = <client's own privatekey>

# server-side knobs: copy verbatim, both sides must match
S1 = 25
S2 = 25
S3 = 25
S4 = 25
H1 = 84
H2 = 86
H3 = 88
H4 = 90
HeaderProtectionKey = <the shared hpk.txt value if AWG_HPK is set server-side>

# client-side only (never needed on the server)
Jc = 4
Jmin = 40
Jmax = 70

[Peer]
PublicKey = <server's, from report.sh>
Endpoint = <host>:1063         # server's public IP or DNS name
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
```

`::/0` closes the client-side IPv6 leak: with only `0.0.0.0/0` a dual-stack
client keeps using its native IPv6 beside the tunnel, and dual-stack services
see (and block) the client's real IPv6 address instead of the chain exit. All
IPv6 routed into the tunnel is dropped server-side (peer allowed-ips are
IPv4-only), and native IPv6 returns when the tunnel goes down.

Verify from the server side: `report.sh` prints `latest handshake` and
transfer counters for each established peer.

## Env

| Var | Default | Notes |
|---|---|---|
| `AWG_PEERS` | — | required, `name:PUBKEY,name2:PUBKEY` |
| `AWG_POOL` | `10.10.30.0/24` | must not overlap the container's own subnet |
| `AWG_HPK` | — (off) | shared HeaderProtectionKey, identical both sides |
| `CHAIN_SOCKS_HOST` | `vpndogs-router` | SOCKS in of the router chain |
| `CHAIN_SOCKS_PORT` | `1070` | SOCKS in port |

## Troubleshooting

- **Handshake never completes** (`awg show` lists a peer with no handshake)
  — the obfuscation parameters or `HeaderProtectionKey` do not match on the
  two sides. Every one of S1–S4, H1–H4 and the HPK must be identical on the
  server and in the client conf. If the client is older than AWG 3.1, it
  ignores these params entirely — upgrade it first.
- **`awg-keys` volume lost/rotated** — the server key is gone. The next boot
  generates a NEW key, so every client conf's `PublicKey = <server>` goes
  stale until you re-distribute the (new) key from `report.sh`.
- **Enabled without creds** — `AWG_PEERS` is required; with the profile
  enabled but vars missing, the entrypoint exits `FATAL: AWG_PEERS is
  required` and the container restart-loops. Set `AWG_PEERS` or disable the
  profile.
- **Traffic enters but never exits** — check `report.sh`: the policy route
  must show `default dev tun0` in `table 200` and both daemons must be UP
  (`== Processes ==`). If hev-socks5-tunnel's socks server is not reachable,
  `route.final` traffic is dropped.
- **Host UDP 1063 collision** — docker port publish fails with `Address
  already in use`; stop whatever binds 1063/udp or change only the *host*
  side of the mapping (`<other>:1063/udp`).

## E2E checklist

See `deploy/`'s stack note and the vpndogs stack's `configs/check.sh` for
the domestic/remote/blackhole egress matrix this node is expected to pass
through the chain.
