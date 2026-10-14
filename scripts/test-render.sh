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
HPK="$PUB1"

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
    "exit_is" "/30 3peers" "render_run 'AWG_PEERS=p1:$PUB1,p2:$PUB2,p3:$PUB1' AWG_POOL=10.10.30.0/30" 2
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
# Task 3 adds: case8 keygen+reuse, case9 live up + report redaction, case10 overlap
# ---------------------------------------------------------------------------
boot_cases() { :; }

[ "$MODE" = local ] && {
    echo "=== LOCAL RENDER TESTS (cases 1-6 only) ==="
    main_cases
    exit "$fail"
}

echo "=== DOCKER MODE TESTS ==="
main_cases
boot_cases
exit "$fail"
