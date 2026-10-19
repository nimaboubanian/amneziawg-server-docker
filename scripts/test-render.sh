#!/usr/bin/env bash
# test-render.sh
set -uo pipefail

IMG="${IMAGE:-amneziawg-server:latest}"
MODE=docker
[ "${1:-}" = "--local" ] && MODE=local

# 43 base64 chars + '=': awg's parser also demands canonical padding — the 43rd
# char's low 2 bits must be 0.
HERE="$(cd "$(dirname "$0")" && pwd)"
ENTRY="$HERE/entrypoint.sh"
fail=0
LAST_OUT=""

PUB1="aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789+/AbCdE="
PUB2="ZyXwVuTsRqPoNmLkJiHgFeDcBa9876543210+/fEdCA="
PUB3="0BcDeFgHiJkLmNoPqRsTuVwXyZ0123456789+/AbCdI="  # third distinct peer key
# distinct from PUB1/PUB2: if HPK equalled a peer pubkey, the redaction check
# "report contains no HPK" would trip on that peer's PublicKey line
HPK="wBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789+/AbCdQ="

FIX_ENV=(AWG_PEERS="phone:$PUB1,laptop:$PUB2")
FIX_DE=()
for kv in "${FIX_ENV[@]}"; do FIX_DE+=(-e "$kv"); done

# run_env KEY=VAL... cmd args... — run the entrypoint subcommand with env
# (FIX_ENV + KEY=VAL args), local or in a --network none container per MODE
run_env() {
    local host_env=("${FIX_ENV[@]}") docker_env=("${FIX_DE[@]}") kv args=()
    for kv in "$@"; do
        if [[ "$kv" == *=* ]]; then
            host_env+=("$kv")
            docker_env+=(-e "$kv")
        else
            args+=("$kv")
        fi
    done
    if [ "$MODE" = local ]; then
        env "${host_env[@]}" bash "$ENTRY" "${args[@]}" 2>&1
    else
        docker run --rm --network none "${docker_env[@]}" \
            --entrypoint /usr/local/bin/entrypoint.sh "$IMG" "${args[@]}" 2>&1
    fi
}

image_run() { docker run --rm "${FIX_DE[@]}" "$@"; }

block() { printf '%s\n' "$2" | awk -v b="# === $1 ===" '$0==b{f=1;next} /^# === /{f=0} f'; }

assert() { # name jq-filter json
    local name="$1" filter="$2" json="$3" res
    if res="$(printf '%s' "$json" | jq -e "$filter" 2>&1)"; then
        echo "$name: PASS"
    else
        echo "$name: FAIL"
        printf '%s\n' "$res" >&2
        fail=1
    fi
}

eq() { local name="$1" got="$2" want="$3"; [ "$got" = "$want" ] && echo "$name: PASS" || { echo "$name: FAIL"; printf 'want:\n%s\n\ngot:\n%s\n' "$want" "$got" >&2; fail=1; }; }
has() { local name="$1" text="$2" pat="$3"; printf '%s\n' "$text" | grep -qF "$pat" && echo "$name: PASS" || { echo "$name: FAIL"; printf 'expected %q in:\n%s\n' "$pat" "$text" >&2; fail=1; }; }
lacks() { local name="$1" text="$2" pat="$3"; printf '%s\n' "$text" | grep -qF "$pat" && { echo "$name: FAIL"; printf 'found %q in:\n%s\n' "$pat" "$text" >&2; fail=1; } || echo "$name: PASS"; }

# run_is name want cmd... — run the command as real argv, compare exit code
run_is() {
    local name="$1" want="$2" rc=0
    shift 2
    set +e; "$@" >/tmp/out.$$ 2>&1; rc=$?
    LAST_OUT="$(cat /tmp/out.$$)"; rm -f /tmp/out.$$ || true
    if [ "$rc" = "$want" ]; then
        echo "$name: PASS (exit $rc)"
    else
        echo "$name: FAIL (exit $rc, want $want)"
        printf '%s\n' "$LAST_OUT" >&2
        fail=1
    fi
}

# ---------- Cases 1-6 (local-renderable) ----------

case1() {
    local out="" awg="" hv=""
    out="$(run_env render)" || { echo "case1 render: FAIL (rc $?)" >&2; fail=1; return; }
    awg="$(block "awg0.conf" "$out")"
    hv="$(block "hev.yml" "$out")"
    echo "=== CASE 1 ==="
    has "awg0 has ListenPort 1063" "$awg" "ListenPort = 1063"
    has "awg0 has Address 10.10.30.1/24" "$awg" "Address = 10.10.30.1/24"
    has "awg0 has PrivateKey placeholder" "$awg" "PrivateKey = <generated-at-boot>"
    for kv in "S1 = 25" "S2 = 25" "S3 = 25" "S4 = 25"; do has "awg0 $kv" "$awg" "$kv"; done
    for kv in "H1 = 84" "H2 = 86" "H3 = 88" "H4 = 90"; do has "awg0 $kv" "$awg" "$kv"; done
    has "peer 1 name comment" "$awg" "# phone"
    has "peer 1 AllowedIPs" "$awg" "AllowedIPs = 10.10.30.2/32"
    has "peer 2 name comment" "$awg" "# laptop"
    has "peer 2 AllowedIPs" "$awg" "AllowedIPs = 10.10.30.3/32"
    has "PUB1 present" "$awg" "$PUB1"
    has "PUB2 present" "$awg" "$PUB2"
    lacks "no HeaderProtectionKey line when AWG_HPK unset" "$awg" "HeaderProtectionKey"
    has "hev tun name" "$hv" "name: tun0"
    has "hev mtu 1380" "$hv" "mtu: 1380"
    has "hev socks server" "$hv" "address: vpndogs-router"
    has "hev socks port" "$hv" "port: 1070"
    has "hev udp associate" "$hv" "udp: udp"
    lacks "hev no udp-in-tcp" "$hv" "udp: tcp"
}

case2() {
    local out="" awg="" hv=""
    out="$(run_env render AWG_POOL=10.99.0.0/22 CHAIN_SOCKS_HOST=router2 CHAIN_SOCKS_PORT=2080 AWG_HPK="$HPK")" || { echo "case2 render: FAIL (rc $?)" >&2; fail=1; return; }
    awg="$(block "awg0.conf" "$out")"
    hv="$(block "hev.yml" "$out")"
    echo "=== CASE 2 ==="
    has "awg0 Address 10.99.0.1/22" "$awg" "Address = 10.99.0.1/22"
    has "peer1 AllowedIPs" "$awg" "AllowedIPs = 10.99.0.2/32"
    has "peer2 AllowedIPs" "$awg" "AllowedIPs = 10.99.0.3/32"
    has "HeaderProtectionKey present when AWG_HPK set" "$awg" "HeaderProtectionKey = $HPK"
    has "hev socks server router2" "$hv" "address: router2"
    has "hev socks port 2080" "$hv" "port: 2080"
}

case3() {
    echo "=== CASE 3 ==="
    run_is "no colon" 2 run_env AWG_PEERS=phone
    has "no-colon message names entry" "$LAST_OUT" "phone"
    run_is "empty name" 2 run_env "AWG_PEERS=:PUB1"
    has "empty-name message names entry" "$LAST_OUT" "got ':PUB1'"
    run_is "bad charset" 2 run_env "AWG_PEERS=ph one:$PUB1"
    has "charset message names entry" "$LAST_OUT" "ph one"
    run_is "bad pubkey" 2 run_env AWG_PEERS=phone:shortkey
    run_is "dup name" 2 run_env "AWG_PEERS=phone:$PUB1,phone:$PUB2"
    run_is "dup pubkey" 2 run_env "AWG_PEERS=phone:$PUB1,laptop:$PUB1"
}

case4() {
    echo "=== CASE 4 ==="
    run_is "/30 3peers" 2 run_env "AWG_PEERS=p1:$PUB1,p2:$PUB2,p3:$PUB3" AWG_POOL=10.10.30.0/30
    has "/30 3peers hits capacity, not dup-key" "$LAST_OUT" "capacity 2"
    run_is "/31 1peer" 2 run_env "AWG_PEERS=p1:$PUB1" AWG_POOL=10.10.30.0/31
    local out; out="$(run_env render "AWG_PEERS=p1:$PUB1,p2:$PUB2" AWG_POOL=10.10.30.0/30)" && echo "/30 2peers: PASS" || { echo "FAIL /30 2peers should render" >&2; printf '%s\n' "$out" >&2; fail=1; }
}

case5() {
    echo "=== CASE 5 ==="
    local out
    out="$(run_env render AWG_PEERS=)" && { echo "FAIL missing AWG_PEERS must exit 2" >&2; fail=1; }
    printf '%s\n' "$out" | grep -q "AWG_PEERS is required" && echo "no AWG_PEERS: PASS" || { echo "FAIL missing AWG_PEERS message wrong" >&2; fail=1; }
    run_is "bad HPK" 2 run_env "AWG_PEERS=phone:$PUB1" AWG_HPK=shortkey
    has "bad HPK message names AWG_HPK" "$LAST_OUT" "AWG_HPK"
}

case6() {
    echo "=== CASE 6 ==="
    run_is "overlap" 0 run_env selftest-cidr 10.10.30.0/24 10.10.30.5/32
    run_is "no-overlap" 1 run_env selftest-cidr 10.10.30.0/24 192.168.1.0/24
}

main_cases() { case1; case2; case3; case4; case5; case6; }

# ---------------------------------------------------------------------------
# boot cases (docker mode only — they need a netns, /dev/net/tun and the daemons)
# ---------------------------------------------------------------------------

boot_cases() {
    # leftover volumes from crashed runs (e.g. ^C during a hung case) would
    # silently reuse a stale key; clean all of them, not just this $$'s
    docker volume ls -q 2>/dev/null | grep '^awg-keys-test-' \
        | xargs -r docker volume rm -f >/dev/null 2>&1 || true
    vol="awg-keys-test-$$"
    # never leak a volume when a case aborts the run
    trap 'docker volume rm -f "$vol" >/dev/null 2>&1 || true' EXIT
    docker volume rm -f "$vol" >/dev/null 2>&1 || true

    # Case 8: first boot generates the server key into the volume; a second
    # boot reuses it (regenerating would stale every client conf overnight)
    key_mode() { # -> server.key mode as an octal string, from inside the volume
        docker run --rm -v "$vol":/etc/amneziawg --entrypoint /bin/sh "$IMG" \
            -c 'stat -c %a /etc/amneziawg/server.key 2>&1'
    }
    pub_of() { # -> derived pubkey, from inside the volume
        docker run --rm -v "$vol":/etc/amneziawg --entrypoint /bin/sh "$IMG" \
            -c 'awg pubkey < /etc/amneziawg/server.key' 2>&1
    }
    run_is "case8 first-boot keys-only" 0 \
        image_run -v "$vol":/etc/amneziawg -e BOOT_STAGE=keys-only "$IMG"
    has "case8 key generated" "$LAST_OUT" "server key generated"
    eq "case8 key mode 600" "$(key_mode)" "600"
    pub1="$(pub_of)"
    if [[ "$pub1" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
        echo "case8 pubkey is real: PASS"
    else
        echo "case8 pubkey is real: FAIL"; fail=1
    fi
    run_is "case8 second boot reuses key" 0 \
        image_run -v "$vol":/etc/amneziawg -e BOOT_STAGE=keys-only "$IMG"
    has "case8 reuse logged" "$LAST_OUT" "reusing existing server key"
    eq "case8 pubkey identical across boots" "$pub1" "$(pub_of)"

    # Case 9: live boot — both userspace daemons up, awg0 configured with the
    # peers, policy route installed (strongest CI-runnable integration check).
    # The entrypoint's own logs stay in LAST_OUT: a boot failure names its step.
    run_is "case9 awg boot" 0 \
        docker run --rm --cap-add NET_ADMIN --device /dev/net/tun \
            -v "$vol":/etc/amneziawg -e BOOT_STAGE=up-only \
            -e AWG_HPK="$HPK" "${FIX_DE[@]}" \
            --entrypoint /bin/sh "$IMG" -c \
            '/usr/local/bin/entrypoint.sh 2>&1 &&
             ip link show awg0 &&
             awg show awg0 &&
             pgrep -f ^hev-socks5-tunnel &&
             pgrep amneziawg-go &&
             ip rule &&
             ip route show table 200'
    has "case9 awg0 up" "$LAST_OUT" "awg0"
    has "case9 peer phone" "$LAST_OUT" "10.10.30.2"
    has "case9 peer laptop" "$LAST_OUT" "10.10.30.3"
    has "case9 policy rule" "$LAST_OUT" "from 10.10.30.0/24 lookup 200"
    has "case9 default route into tun" "$LAST_OUT" "default dev tun0"

    # Review Focus 5: report.sh output is what users paste into issue
    # trackers — the server private key AND the shared AWG_HPK must never
    # appear in it. (No /proc/1/fd/2 log tail: PID1's stderr is dockerd's
    # never-EOF pipe — tailing it would hang.)
    report_out="$(docker run --rm -v "$vol":/etc/amneziawg \
        -e AWG_HPK="$HPK" "${FIX_DE[@]}" \
        --entrypoint /bin/sh "$IMG" -c 'report.sh' 2>&1)"
    key_contents="$(docker run --rm -v "$vol":/etc/amneziawg --entrypoint /bin/sh \
        "$IMG" -c 'cat /etc/amneziawg/server.key')"
    has "case9 report shows the tunnel" "$report_out" "== AmneziaWG =="
    lacks "case9 report hides the server private key" "$report_out" "$key_contents"
    lacks "case9 report hides AWG_HPK" "$report_out" "$HPK"

    # Case 10: a pool overlapping the container's own subnet is fatal (the
    # decrypted traffic would loop back inside the netns — a silent black hole)
    run_is "case10 pool overlap fatal" 2 \
        docker run --rm --cap-add NET_ADMIN -e BOOT_STAGE=up-only \
            -e AWG_POOL=172.17.0.0/16 "${FIX_DE[@]}" "$IMG"
    has "case10 overlap message" "$LAST_OUT" "overlaps"

    docker volume rm -f "$vol" >/dev/null 2>&1 || true
}

[ "$MODE" = local ] && {
    echo "=== LOCAL RENDER TESTS (cases 1-6 only) ==="
    main_cases
    exit "$fail"
}

echo "=== DOCKER MODE TESTS ==="
main_cases
boot_cases
exit "$fail"
