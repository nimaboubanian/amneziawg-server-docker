#!/usr/bin/env bash
# entrypoint.sh — AmneziaWG inbound server for the vpndogs stack.
#
#   entrypoint.sh                       boot: keygen -> configs -> sing-box + awg0
#   entrypoint.sh render                print every rendered config (test path)
#   entrypoint.sh selftest-cidr A B     exit 0 if CIDR A and CIDR B overlap
set -euo pipefail

AWG_POOL="${AWG_POOL:-10.10.30.0/24}"
CHAIN_SOCKS_HOST="${CHAIN_SOCKS_HOST:-vpndogs-router}"
CHAIN_SOCKS_PORT="${CHAIN_SOCKS_PORT:-1070}"
LISTEN_PORT=1063

# Anti-DPI knobs: paddings (S1-S4) move message-type headers off the wire's
# predictable first bytes; H1-H4 are replacement header values. Header
# protection demands S1-S4 >= 12. Clients must send the exact same values —
# the README documents that; the awg parser is the final validator.
S1=25
S2=25
S3=25
S4=25
H1=84
H2=86
H3=88
H4=90

AWG_DIR="/etc/amneziawg"
SERVER_KEY="$AWG_DIR/server.key"
AWG0_CONF="$AWG_DIR/awg0.conf"
SINGBOX_CONF="/etc/sing-box/config.json"
TUN_IFACE="tun0"
ROUTER_TABLE=200

declare -a PEERS=()

log() { echo "[entrypoint] $*" >&2; }
fatal() { echo "FATAL: $*" >&2; exit 2; }

# --- env parsing -----------------------------------------------------------

is_ipv4_addr() {
    local -a o=()
    local part
    IFS=. read -r -a o <<<"$1"
    [[ "${#o[@]}" -eq 4 ]] || return 1
    for part in "${o[@]}"; do
        [[ "$part" =~ ^(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])$ ]] || return 1
    done
}

is_ipv4_cidr() {
    [[ "$1" == */* ]] || return 1
    is_ipv4_addr "${1%%/*}" || return 1
    local mask="${1##*/}"
    [[ "$mask" =~ ^(0|[0-9]|[12][0-9]|3[0-2])$ ]]
}

# AWG keys are plain x25519: 32 bytes base64-encoded = 43 chars + '=' padding,
# canonical (the 43rd char's low 2 bits must be 0 for the parser to accept it).
# Peer pubkeys, the server key and the HPK all share this format.
is_awg_key() {
    [[ "$1" =~ ^[A-Za-z0-9+/]{43}=$ ]]
}

parse_peers() {
    local -a entries=()
    local entry name pubkey seen_names=" " seen_keys=" "
    [[ -n "${AWG_PEERS:-}" ]] || fatal "AWG_PEERS is required (name:PUBKEY,name2:PUBKEY)"
    IFS=',' read -r -a entries <<<"$AWG_PEERS"
    for entry in "${entries[@]}"; do
        [[ "$entry" == *:* ]] || fatal "AWG_PEERS entry without ':' — expected name:PUBKEY (got '$entry')"
        name="${entry%%:*}"
        pubkey="${entry#*:}"   # first colon only: pubkey contains no colon
        [[ -n "$name" ]] || fatal "AWG_PEERS entry with empty name (got '$entry')"
        [[ "$name" =~ ^[A-Za-z0-9_@+-]+$ ]] || fatal "unsupported character in AWG_PEERS entry '$entry': names may use letters, digits and _ @ + - only"
        is_awg_key "$pubkey" || fatal "AWG_PEERS entry '$entry' has a malformed pubkey (expected 44 chars, base64 ending with =)"
        [[ "$seen_names" != *" $name "* ]] || fatal "duplicate AWG_PEERS entry '$name'"
        seen_names="$seen_names$name "
        [[ "$seen_keys" != *" $pubkey "* ]] || fatal "duplicate pubkey in AWG_PEERS: '$pubkey' appears in entry '$entry'"
        seen_keys="$seen_keys$pubkey "
        PEERS+=("$name"$'\t'"$pubkey")
    done
}

validate_env() {
    [[ -n "${AWG_PEERS:-}" ]] || fatal "AWG_PEERS is required (name:PUBKEY,name2:PUBKEY)"
    [[ "$CHAIN_SOCKS_PORT" =~ ^[0-9]+$ ]] || fatal "CHAIN_SOCKS_PORT must be a port number, got '$CHAIN_SOCKS_PORT'"
    is_ipv4_cidr "$AWG_POOL" || fatal "AWG_POOL is not a valid CIDR, got '$AWG_POOL'"
    # Empty = header protection off (rendering just omits the line); set = the
    # same 44-char canonical base64 as any other AWG key.
    if [ -n "${AWG_HPK:-}" ]; then
        is_awg_key "$AWG_HPK" || fatal "AWG_HPK is set but malformed (expected a 44-char base64 key as produced by 'awg genkey')"
    fi
    parse_peers
    # Pool capacity is the only pool guard (Review Focus 3): deterministic
    # addressing must never alias two peers to the same /32. The formula
    # 2^(32-prefix)-2 accounts for the network and server addresses. /31
    # (capacity 0) and /32 (capacity -1) fall out naturally — any non-empty
    # AWG_PEERS is rejected — so no separate "prefix <= 30" check is needed.
    local prefix capacity
    prefix="${AWG_POOL##*/}"
    capacity=$(( (1 << (32 - prefix)) - 2 ))
    (( ${#PEERS[@]} <= capacity )) || fatal "AWG_POOL $AWG_POOL has capacity $capacity but ${#PEERS[@]} peers were given (server takes one address) — pick a larger pool"
}

# --- CIDR helpers ----------------------------------------------------------

ip_to_int() {
    local a b c d
    IFS=. read -r a b c d <<<"$1"
    printf '%d\n' "$(( (a << 24) | (b << 16) | (c << 8) | d ))"
}

int_to_ip() {
    local n="$1"
    printf '%d.%d.%d.%d\n' \
        $(( (n >> 24) & 0xFF )) \
        $(( (n >> 16) & 0xFF )) \
        $(( (n >> 8) & 0xFF )) \
        $(( n & 0xFF ))
}

cidr_overlap() { # exit 0 when the two CIDRs share any address
    local a="$1" b="$2" ai bi ma mb diff
    ai="$(ip_to_int "${a%%/*}")"
    bi="$(ip_to_int "${b%%/*}")"
    ma=$(( 0xFFFFFFFF << (32 - ${a##*/}) & 0xFFFFFFFF ))
    mb=$(( 0xFFFFFFFF << (32 - ${b##*/}) & 0xFFFFFFFF ))
    diff=$(( (ai ^ bi) & 0xFFFFFFFF ))
    (( (diff & ma) == 0 || (diff & mb) == 0 ))
}

# --- renderers -------------------------------------------------------------

render_awg0_conf() {
    # Deterministic addressing (Global Constraints): server = network+1,
    # peer i (0-based, in AWG_PEERS order) = network+2+i, each a /32.
    local addr prefix network server_ip key i=0 entry name pubkey
    addr="${AWG_POOL%%/*}"
    prefix="${AWG_POOL##*/}"
    network="$(ip_to_int "$addr")"
    server_ip="$(int_to_ip $(( network + 1 )))"
    if [[ -s "$SERVER_KEY" ]]; then
        key="$(cat "$SERVER_KEY")"
    else
        key="<generated-at-boot>"
    fi
    cat <<EOF
[Interface]
Address = $server_ip/$prefix
ListenPort = $LISTEN_PORT
PrivateKey = $key
S1 = $S1
S2 = $S2
S3 = $S3
S4 = $S4
H1 = $H1
H2 = $H2
H3 = $H3
H4 = $H4
EOF
    if [ -n "${AWG_HPK:-}" ]; then
        echo "HeaderProtectionKey = $AWG_HPK"
    fi
    echo
    for entry in "${PEERS[@]}"; do
        IFS=$'\t' read -r name pubkey <<<"$entry"
        cat <<EOF
[Peer]
# $name
PublicKey = $pubkey
AllowedIPs = $(int_to_ip $(( network + 2 + i )))/32

EOF
        i=$(( i + 1 ))
    done
}

render_singbox_conf() {
    # auto_route stays off on purpose: the entrypoint owns routing via a policy
    # rule so only decrypted pool-source traffic enters the tun.
    jq -n --arg host "$CHAIN_SOCKS_HOST" --argjson port "$CHAIN_SOCKS_PORT" '{
        log: {level: "warn"},
        inbounds: [{
            type: "tun",
            tag: "tun-in",
            interface_name: "tun0",
            address: ["198.18.0.1/30"],
            mtu: 1380,
            auto_route: false,
            strict_route: false
        }],
        outbounds: [
            {type: "direct", tag: "direct-out"},
            {type: "socks", tag: "chain-out", server: $host, server_port: $port}
        ],
        route: {final: "chain-out"}
    }'
}

cmd_render() {
    validate_env
    echo "# === awg0.conf ==="
    render_awg0_conf
    echo "# === sing-box.json ==="
    render_singbox_conf
}

# --- boot (main filled in by Task 3: keygen, daemons, supervision) ---------

main() {
    echo "boot not implemented" >&2
    exit 1
}

case "${1:-}" in
    render)
        cmd_render
        ;;
    selftest-cidr)
        shift
        cidr_overlap "$@"
        ;;
    *)
        main
        ;;
esac
