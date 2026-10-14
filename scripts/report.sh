#!/bin/sh
# report.sh — quick diagnostics. Invoked via `docker exec <container> report.sh`.
set -u

echo "== Processes =="
for p in sing-box amneziawg-go; do
    pid=$(pgrep -x "$p" 2>/dev/null | head -1)
    if [ -n "$pid" ]; then echo "  $p UP   pid=$pid"; else echo "  $p NOT RUNNING"; fi
done
awg show awg0 >/dev/null 2>&1 && echo "  awg0 interface UP" || echo "  awg0 interface DOWN"

echo
echo "== Interfaces and routing =="
ip -4 -o addr show 2>/dev/null | sed 's/^/  /'
ip rule show 2>/dev/null | sed 's/^/  /'
# `cmd | sed || fallback` never runs the fallback: the pipeline's status is sed's.
if ! ip route show table 200 2>/dev/null | grep -q .; then
    echo "  (table 200 empty — policy route not installed)"
else
    ip route show table 200 2>/dev/null | sed 's/^/  /'
fi

echo
echo "== AmneziaWG =="
awg show awg0 2>/dev/null | sed 's/^/  /' || echo "  (awg0 down)"

echo
echo "== Server public key =="
# This is the line client confs copy into their PublicKey.
awg pubkey < /etc/amneziawg/server.key 2>/dev/null | sed 's/^/  copy into client confs: /' \
    || echo "  (server.key missing)"

echo
echo "== Obfuscation constants (must match on BOTH sides) =="
echo "  S1 = 25  S2 = 25  S3 = 25  S4 = 25"
echo "  H1 = 84  H2 = 86  H3 = 88  H4 = 90"
echo "  HeaderProtectionKey: read from the server env only —"
echo "  docker exec vpndogs-awg-inbound sh -c 'printenv AWG_HPK'"

echo
echo "== Egress (via the chain) =="
echo "  tun peer configured as socks ${CHAIN_SOCKS_HOST:-vpndogs-router}:${CHAIN_SOCKS_PORT:-1070}"

echo
echo "== Config (secrets redacted) =="
# This output is what users paste into issue trackers: the server private key
# (PrivateKey) and the shared HeaderProtectionKey (AWG_HPK) must never appear
# in it.
env | grep -E '^(AWG_|CHAIN_)' | sort \
    | sed 's/^\(AWG_HPK=\).*/\1<redacted>/' | sed 's/^/  /'
if [ -f /etc/amneziawg/awg0.conf ]; then
    sed -e 's/^\(PrivateKey = \).*/\1<redacted>/' \
        -e 's/^\(HeaderProtectionKey = \).*/\1<redacted>/' \
        /etc/amneziawg/awg0.conf | sed 's/^/  /'
fi
