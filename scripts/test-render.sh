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

render_run() {
    local host_env=("${FIX_ENV[@]}") docker_env=() kv
    for kv in "$@"; do
        host_env+=("$kv")
        docker_env+=(-e "$kv")
    done
    if [ "$MODE" = local ]; then
        env "${host_env[@]}" bash "$ENTRY" render 2>&1
    else
        docker run --rm --network none "${FIX_DE[@]}" "${docker_env[@]}" \
            --entrypoint /usr/local/bin/entrypoint.sh "$IMG" render 2>&1
    fi
}

render() { render_run "$@" || true; }

subcmd() {
    local host_env=() docker_env=() kv
    for kv in "$@"; do
        if [[ "$kv" == *=* ]]; then
            host_env+=("$kv")
            docker_env+=(-e "$kv")
        fi
    done
    if [ "$MODE" = local ]; then
        env "${host_env[@]}" bash "$ENTRY" "$@"
    else
        docker run --rm --network none "${docker_env[@]}" --entrypoint /usr/local/bin/entrypoint.sh "$IMG" "$@"
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
matches() {
    local name="$1" regex="$2" got="$3"
    if [[ "$got" =~ $regex ]]; then
        echo "$name: PASS"
    else
        echo "$name: FAIL"
        printf '  %q does not match %s\n' "$3" "$2" >&2
        fail=1
    fi
}

exit_is() { # name cmd exit-code
    local name="$1" cmd="$2" want="$3" rc=0
    set +e; eval "$cmd" >/tmp/out.$$ 2>&1; rc=$?
    LAST_OUT="$(cat /tmp/out.$$)"; rm -f /tmp/out.$$ || true
    if [ "$rc" = "$want" ]; then
        echo "$name: PASS (exit $rc)"
    else
        echo "$name: FAIL (exit $rc, want $want)"
        printf '%s\n' "$LAST_OUT" >&2
        fail=1
    fi
}

# run_is name want cmd... — like exit_is but takes the command as real argv
# (no eval), for the boot cases whose docker invocations quote badly in eval.
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
    local out="" awg="" sb=""
    out="$(render)" || { echo "case1 render: FAIL (rc $?)" >&2; fail=1; return; }
    awg="$(block "awg0.conf" "$out")"
    sb="$(block "sing-box.json" "$out")"
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
    assert "sb tun name" '.inbounds[] | select(.type=="tun") | .interface_name == "tun0"' "$sb"
    assert "sb mtu 1380" '.inbounds[] | select(.type=="tun") | .mtu == 1380' "$sb"
    assert "sb auto_route false" '.inbounds[] | select(.type=="tun") | .auto_route == false' "$sb"
    assert "sb route final is socks" '.route.final | contains("chain-out")' "$sb"
    assert "sb socks has router" '.outbounds[] | select(.tag=="chain-out") | .type=="socks"' "$sb"
    assert "sb socks server" '.outbounds[] | select(.tag=="chain-out") | .server == "vpndogs-router"' "$sb"
    assert "sb socks port" '.outbounds[] | select(.tag=="chain-out") | .server_port == 1070' "$sb"
}

case2() {
    local out="" awg="" sb=""
    out="$(render AWG_POOL=10.99.0.0/22 CHAIN_SOCKS_HOST=router2 CHAIN_SOCKS_PORT=2080 AWG_HPK="$HPK")" || { echo "case2 render: FAIL (rc $?)" >&2; fail=1; return; }
    awg="$(block "awg0.conf" "$out")"
    sb="$(block "sing-box.json" "$out")"
    echo "=== CASE 2 ==="
    has "awg0 Address 10.99.0.1/22" "$awg" "Address = 10.99.0.1/22"
    has "peer1 AllowedIPs" "$awg" "AllowedIPs = 10.99.0.2/32"
    has "peer2 AllowedIPs" "$awg" "AllowedIPs = 10.99.0.3/32"
    has "HeaderProtectionKey present when AWG_HPK set" "$awg" "HeaderProtectionKey = $HPK"
    assert "sb socks server router2" '.outbounds[] | select(.tag=="chain-out") | .server == "router2"' "$sb"
    assert "sb socks port 2080" '.outbounds[] | select(.tag=="chain-out") | .server_port == 2080' "$sb"
}

case3() {
    echo "=== CASE 3 ==="
    "exit_is" "no colon" "render_run AWG_PEERS=phone" 2
    has "no-colon message names entry" "$LAST_OUT" "phone"
    "exit_is" "empty name" "render_run AWG_PEERS=:PUB1" 2
    has "empty-name message names entry" "$LAST_OUT" "got ':PUB1'"
    "exit_is" "bad charset" "render_run 'AWG_PEERS=ph one:PUB1'" 2
    has "charset message names entry" "$LAST_OUT" "ph one"
    "exit_is" "bad pubkey" "render_run AWG_PEERS=phone:shortkey" 2
    "exit_is" "dup name" "render_run 'AWG_PEERS=phone:$PUB1,phone:$PUB2'" 2
    "exit_is" "dup pubkey" "render_run 'AWG_PEERS=phone:$PUB1,laptop:$PUB1'" 2
}

case4() {
    echo "=== CASE 4 ==="
    "exit_is" "/30 3peers" "render_run 'AWG_PEERS=p1:$PUB1,p2:$PUB2,p3:$PUB3' AWG_POOL=10.10.30.0/30" 2
    has "/30 3peers hits capacity, not dup-key" "$LAST_OUT" "capacity 2"
    "exit_is" "/31 1peer" "render_run 'AWG_PEERS=p1:$PUB1' AWG_POOL=10.10.30.0/31" 2
    local out; out="$(render_run AWG_PEERS="p1:$PUB1,p2:$PUB2" AWG_POOL=10.10.30.0/30)" && echo "/30 2peers: PASS" || { echo "FAIL /30 2peers should render" >&2; printf '%s\n' "$out" >&2; fail=1; }
}

case5() {
    echo "=== CASE 5 ==="
    local out
    out="$(render_run AWG_PEERS=)" && { echo "FAIL missing AWG_PEERS must exit 2" >&2; fail=1; }
    printf '%s\n' "$out" | grep -q "AWG_PEERS is required" && echo "no AWG_PEERS: PASS" || { echo "FAIL missing AWG_PEERS message wrong" >&2; fail=1; }
    "exit_is" "bad HPK" "render_run AWG_PEERS=phone:$PUB1 AWG_HPK=shortkey" 2
    has "bad HPK message names AWG_HPK" "$LAST_OUT" "AWG_HPK"
}

case6() {
    echo "=== CASE 6 ==="
    "exit_is" "overlap" "subcmd selftest-cidr 10.10.30.0/24 10.10.30.5/32" 0
    "exit_is" "no-overlap" "subcmd selftest-cidr 10.10.30.0/24 192.168.1.0/24" 1
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
    matches "case8 pubkey is real" '^[A-Za-z0-9+/]{43}=$' "$pub1"
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
             pgrep -x sing-box &&
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
