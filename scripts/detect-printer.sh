#!/usr/bin/env bash
# scripts/detect-printer.sh
#
# Find Brother MFC-7860DN on the local network without knowing its IP.
#
# Strategy:
#   1. mDNS / DNS-SD via avahi-browse for _pdl-datastream._tcp
#   2. mDNS for _ipp._tcp
#   3. ARP cache (recently contacted hosts)
#   4. Manual subnet scan with /24 probing (only if avahi is missing)
#
# Output: prints candidate IPs, one per line. First one wins for install.sh.
#
# Usage:
#   ./detect-printer.sh                  # use default
#   ./detect-printer.sh --subnet 10.0.0.0/24
set -euo pipefail

SUBNET=""
while [ $# -gt 0 ]; do
    case "$1" in
        --subnet) SUBNET="${2:-}"; shift 2;;
        *)         echo "unknown: $1" >&2; exit 1;;
    esac
done

say() { printf '\033[1;34m[detect]\033[0m %s\n' "$*"; }

check_port() {
    local ip="$1" port="$2"
    timeout 2 bash -c "exec 3<>/dev/tcp/$ip/$port" 2>/dev/null
}

# 1. mDNS via avahi
if command -v avahi-browse >/dev/null 2>&1; then
    say "querying mDNS..."
    mapfile -t mdns_hits < <(avahi-browse -art _pdl-datastream._tcp 2>/dev/null \
        | awk -F'[][]' '/Brother MFC-7860DN/ {print $4}')
    if [ "${#mdns_hits[@]}" -gt 0 ]; then
        say "mDNS hit:"
        printf '  %s\n' "${mdns_hits[@]}"
        printf '%s\n' "${mdns_hits[@]}"
        exit 0
    fi
    mapfile -t mdns_hits < <(avahi-browse -art _ipp._tcp 2>/dev/null \
        | awk -F'[][]' '/Brother MFC-7860DN/ {print $4}')
    if [ "${#mdns_hits[@]}" -gt 0 ]; then
        say "mDNS hit (IPP):"
        printf '  %s\n' "${mdns_hits[@]}"
        printf '%s\n' "${mdns_hits[@]}"
        exit 0
    fi
fi

# 2. ARP cache (works only if we already talked to it)
if [ -f /proc/net/arp ]; then
    mapfile -t arp_hits < <(awk 'NR>1 && $4!="00:00:00:00:00:00" {print $1}' /proc/net/arp)
    for ip in "${arp_hits[@]}"; do
        if check_port "$ip" 9100; then
            say "arp cache + port 9100 hit: $ip"
            echo "$ip"
            exit 0
        fi
    done
fi

# 3. Subnet scan
if [ -z "$SUBNET" ]; then
    iface=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $5; exit}')
    [ -z "$iface" ] && iface=$(ip route | awk '/default/ {print $5; exit}')
    SUBNET=$(ip -o -4 addr show dev "$iface" 2>/dev/null | awk '{print $4}' | head -1)
fi
say "scanning $SUBNET for port 9100..."

base="${SUBNET%.*}"
[ "$SUBNET" = "${SUBNET%.*}" ] && SUBNET="${SUBNET}.0/24"

# /24 is 256 IPs; use parallel probe with xargs -P
seq 1 254 | xargs -I{} -P 32 bash -c '
    ip="'"$base"'{}"
    if timeout 1 bash -c "exec 3<>/dev/tcp/$ip/9100" 2>/dev/null; then
        # try IPP attribute query to confirm it is actually a printer
        if timeout 1 bash -c "exec 3<>/dev/tcp/$ip/631" 2>/dev/null; then
            echo "$ip"
        fi
    fi
' | sort -u | head -5

exit 0