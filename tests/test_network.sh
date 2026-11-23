#!/usr/bin/env bash
# Exercise the LAN-IP detection a default install relies on: a browser on
# another machine needs this host's real address, not "localhost" (which
# resolves to itself, not the server) - see Design-Decisions #22.
#
# `ip` and `hostname` are stubbed as shell functions, which bash resolves
# before anything on PATH, so no real networking is touched.
set -uo pipefail

ROOT="${1:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${ROOT}/lib/common.sh"

pass=0; fail=0
check() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        printf 'PASS  %s\n' "$desc"; pass=$((pass+1))
    else
        printf 'FAIL  %s\n        expected: [%s]\n        actual:   [%s]\n' "$desc" "$expected" "$actual"
        fail=$((fail+1))
    fi
}

T="$(mktemp -d)"

# --- Primary path: the default route's source address ----------------------
ip() { printf '1.1.1.1 via 192.168.1.1 dev eth0 src 192.168.1.50 uid 0\n'; }
hostname() { printf 'should-not-be-used\n'; }
check "prefers the default route's src address" "192.168.1.50" "$(detect_lan_ip)"

# --- Fallback: no default route, hostname -I used instead ------------------
ip() { return 1; }
hostname() { printf '172.17.0.1 192.168.1.51\n'; }
check "falls back to hostname -I"       "192.168.1.51" "$(detect_lan_ip)"

# The fallback must skip a Docker bridge address even when it comes first.
ip() { return 1; }
hostname() { printf '172.20.5.1 10.0.0.9\n'; }
check "fallback skips docker bridge range" "10.0.0.9" "$(detect_lan_ip)"

# A real LAN on 172.16.0.0/16 itself (outside Docker's default pool) must
# survive the filter.
ip() { return 1; }
hostname() { printf '172.16.0.42\n'; }
check "172.16.0.0/16 is not treated as a docker bridge" "172.16.0.42" "$(detect_lan_ip)"

# --- Nothing usable anywhere -------------------------------------------------
ip() { return 1; }
hostname() { printf '\n'; }
check "empty when nothing detected" "" "$(detect_lan_ip)"

# --- lan_ip_or_localhost: never fails, warns on the fallback ----------------
ip() { return 1; }
hostname() { printf '\n'; }
out="$(lan_ip_or_localhost 2>"${T}/warn")"
check "falls back to localhost"     "localhost" "$out"
check "warns on the fallback"       "1" "$([[ -s "${T}/warn" ]] && echo 1 || echo 0)"

ip() { printf '1.1.1.1 via 10.0.0.1 dev eth0 src 10.0.0.5 uid 0\n'; }
check "returns the detected address without warning" "10.0.0.5" "$(lan_ip_or_localhost 2>"${T}/warn2")"
check "no warning when detection succeeds" "0" "$([[ -s "${T}/warn2" ]] && echo 1 || echo 0)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
rm -rf "$T"
[[ $fail -eq 0 ]]
