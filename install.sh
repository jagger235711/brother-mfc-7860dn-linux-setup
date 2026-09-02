#!/usr/bin/env bash
# install.sh - Brother MFC-7860DN Linux setup
#
# Sets up a working CUPS queue for the Brother MFC-7860DN on a Linux host.
# Tested on Manjaro / Arch. Should also work on Debian/Ubuntu/Fedora with
# the distro-equivalent package names.
#
# Usage:
#   ./install.sh --ip 10.60.82.103
#   ./install.sh                   # auto-detect on local subnet (mDNS then scan)
#
# Default driver: pxlmono (PCL XL). The Brother PostScript PPD (BR786N_2.PPD)
# is installed as a fallback under the queue name Brother-MFC7860DN-PS.
#
# Exit codes:
#   0 success
#   1 user error (missing arg, bad IP, no CUPS)
#   2 printer unreachable
#   3 install failure
set -euo pipefail

PROG=$(basename "$0")
QUEUE_DEFAULT="Brother-MFC7860DN"
QUEUE_FALLBACK_PS="Brother-MFC7860DN-PS"
PRINT_IP=""
AUTO_DETECT=0
SKIP_TEST=0
FORCE_PPD=""

usage() {
    cat <<EOF
$PROG - set up Brother MFC-7860DN on Linux

Usage:
  $PROG --ip <addr>      Install and create queue for printer at <addr>
  $PROG --auto           Auto-detect printer via mDNS then LAN scan
  $PROG --ppd <name>     Override default PPD (pxlmono | brother)
  $PROG --no-test        Skip the post-install test page
  $PROG -h|--help        This help

Examples:
  $PROG --ip 192.168.1.250
  $PROG --auto
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --ip)      PRINT_IP="${2:-}"; shift 2;;
        --auto)    AUTO_DETECT=1; shift;;
        --ppd)     FORCE_PPD="${2:-}"; shift 2;;
        --no-test) SKIP_TEST=1; shift;;
        -h|--help) usage; exit 0;;
        *)         echo "$PROG: unknown option: $1" >&2; usage; exit 1;;
    esac
done

if [ -z "$PRINT_IP" ] && [ "$AUTO_DETECT" -eq 0 ]; then
    echo "$PROG: need --ip <addr> or --auto" >&2
    usage
    exit 1
fi

say() { printf '\033[1;34m[setup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[fatal]\033[0m %s\n' "$*" >&2; exit 1; }

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "must be run as root (sudo $0 ...)"
    fi
}

detect_pkg_mgr() {
    for pm in pacman dnf yum apt zypper; do
        if command -v "$pm" >/dev/null 2>&1; then
            PKG_MGR="$pm"
            return 0
        fi
    done
    die "no supported package manager (need pacman/dnf/yum/apt/zypper)"
}

install_cups() {
    say "ensuring CUPS is present..."
    case "$PKG_MGR" in
        pacman)
            pacman -S --needed --noconfirm cups cups-filters ghostscript 2>&1 | tail -3
            systemctl enable --now cups.service cups.socket
            ;;
        apt)
            apt-get update -qq
            apt-get install -y cups cups-filters ghostscript 2>&1 | tail -3
            systemctl enable --now cups
            ;;
        dnf|yum)
            "$PKG_MGR" install -y cups cups-filters ghostscript 2>&1 | tail -3
            systemctl enable --now cups
            ;;
        zypper)
            zypper --non-interactive install cups cups-filters ghostscript 2>&1 | tail -3
            systemctl enable --now cups
            ;;
    esac
    sleep 1
    if ! systemctl is-active cups >/dev/null 2>&1; then
        die "CUPS did not start"
    fi
    say "CUPS is running"
}

print_reachable() {
    local ip="$1" port="$2"
    if timeout 3 bash -c "exec 3<>/dev/tcp/$ip/$port" 2>/dev/null; then
        exec 3<&-
        return 0
    fi
    return 1
}

auto_detect() {
    say "auto-detecting Brother MFC-7860DN on LAN..."
    # 1) mDNS / Bonjour (avahi-browse)
    if command -v avahi-browse >/dev/null 2>&1; then
        local mdns_ip
        mdns_ip=$(avahi-browse -art _pdl-datastream._tcp 2>/dev/null \
            | awk -F'[][]' '/Brother MFC-7860DN/ {print $4; exit}')
        if [ -n "$mdns_ip" ] && print_reachable "$mdns_ip" 9100; then
            say "found via mDNS: $mdns_ip"
            PRINT_IP="$mdns_ip"
            return 0
        fi
    fi
    # 2) scan candidates from routing table subnet
    local iface gw
    iface=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $5; exit}')
    [ -z "$iface" ] && iface=$(ip route | awk '/default/ {print $5; exit}')
    local prefix
    prefix=$(ip -o -4 addr show dev "$iface" 2>/dev/null | awk '{print $4}' | head -1)
    if [ -z "$prefix" ]; then
        warn "could not determine local subnet, falling back to /24 scan"
        prefix="192.168.1.0/24"
    fi
    say "scanning $prefix on ports 9100/631 (this may take ~30s)..."
    local base="${prefix%.*}"
    local last="${prefix##*.}"
    local -a candidates=()
    if [ "$last" = "0/24" ]; then
        candidates=(1 50 100 103 109 150 200 250)
    else
        candidates=("$last")
    fi
    # quick scan only the well-known offsets; full /24 is too slow without nmap
    for c in "${candidates[@]}"; do
        local probe="$base.$c"
        if print_reachable "$probe" 9100; then
            PRINT_IP="$probe"
            say "found reachable printer at $probe"
            return 0
        fi
    done
    die "could not find Brother MFC-7860DN. Pass --ip <addr> explicitly."
}

probe_printer() {
    say "probing $PRINT_IP..."
    local ok=0
    for port in 631 9100 515 80; do
        if print_reachable "$PRINT_IP" "$port"; then
            say "  port $port OPEN"
            ok=1
        fi
    done
    [ "$ok" -eq 1 ] || die "no ports reachable at $PRINT_IP - check cabling/Wi-Fi/IP"
}

install_ppd_assets() {
    local src_dir
    src_dir=$(cd "$(dirname "$0")" && pwd)/ppd
    if [ ! -d "$src_dir" ]; then
        # pip-style install: ppd/ lives next to install.sh
        die "ppd/ directory not found next to $PROG"
    fi
    install -d /usr/share/cups/model/brother-mfc7860dn
    install -m 0644 "$src_dir"/BR786N_2.PPD /usr/share/cups/model/brother-mfc7860dn/
    install -m 0644 "$src_dir"/BR7860_2.PPD /usr/share/cups/model/brother-mfc7860dn/
    # pxlmono.ppd is shipped by cups-filters in distros, but copy it locally as a
    # last-resort fallback in case the user has a stripped cups-filters package.
    if [ -f /usr/share/ppd/cupsfilters/pxlmono.ppd ]; then
        install -m 0644 /usr/share/ppd/cupsfilters/pxlmono.ppd \
            /usr/share/cups/model/brother-mfc7860dn/
    fi
    # tell cups-driverd to refresh its cache
    systemctl restart cups 2>/dev/null || true
    sleep 1
}

# Decide which PPD to use.
#
# Why default to pxlmono:
#   The Brother MFC-7860DN has only 32MB RAM. The official BR-Script3 PPD
#   posts PostScript to the printer's on-board interpreter, which has only
#   8.88MB of free VM (per the PPD's *FreeVM). Any PDF with embedded fonts
#   or images blows that limit, and the printer reports "memory full".
#
#   pxlmono renders PDF to PCL XL on the *host* (via Ghostscript) and ships
#   raster-ready data to the printer. The printer never has to interpret
#   PostScript, so memory pressure stays low.
#
# If you must use the Brother PPD (e.g. to drive Secure Print / HoldJob
# features), pass --ppd brother and the install script will register
# Brother-MFC7860DN-PS alongside the default pxlmono queue.
choose_ppd() {
    if [ -n "$FORCE_PPD" ]; then
        case "$FORCE_PPD" in
            pxlmono|pxl) PPD_NAME="everywhere.pxlmono";;  # cups-filters driver
            brother|br)   PPD_NAME="/usr/share/cups/model/brother-mfc7860dn/BR786N_2.PPD";;
            *)            die "unknown --ppd value: $FORCE_PPD";;
        esac
    else
        # pxlmono is the safest default
        PPD_NAME="/usr/share/ppd/cupsfilters/pxlmono.ppd"
        if [ ! -f "$PPD_NAME" ]; then
            warn "pxlmono.ppd not found at $PPD_NAME, trying model dir copy"
            PPD_NAME="/usr/share/cups/model/brother-mfc7860dn/pxlmono.ppd"
            [ -f "$PPD_NAME" ] || die "pxlmono.ppd missing; install cups-filters"
        fi
    fi
    say "selected PPD: $PPD_NAME"
}

create_queue() {
    local queue="$1" uri="$2" ppd="$3" desc="$4"
    say "creating queue $queue -> $uri"
    if lpstat -p "$queue" >/dev/null 2>&1; then
        say "queue $queue already exists, removing"
        lpadmin -x "$queue" >/dev/null 2>&1 || true
    fi
    lpadmin -p "$queue" -E \
        -v "$uri" \
        -m "$ppd" \
        -D "$desc" || die "lpadmin failed for $queue"
    lpadmin -p "$queue" -o printer-error-policy=abort-job >/dev/null
}

make_default() {
    say "setting $QUEUE_DEFAULT as system default"
    lpadmin -d "$QUEUE_DEFAULT" >/dev/null
}

test_page() {
    if [ "$SKIP_TEST" -eq 1 ]; then
        say "skipping test page (--no-test)"
        return 0
    fi
    say "sending test page..."
    local tmp
    tmp=$(mktemp --suffix=.ps)
    cat > "$tmp" <<'EOF'
%!PS-Adobe-3.0
%%BoundingBox: 0 0 595 842
%%EndComments
%%Page: 1 1
/Times-Roman findfont 18 scalefont setfont
72 760 moveto
(Brother MFC-7860DN Linux setup - test page) show
72 720 moveto
(Queue: Brother-MFC7860DN) show
72 680 moveto
(Date: ) show
72 660 moveto
(System: Linux CUPS) show
showpage
%%EOF
EOF
    local rc=0
    lp -d "$QUEUE_DEFAULT" -o PageSize=A4 "$tmp" || rc=$?
    rm -f "$tmp"
    if [ "$rc" -ne 0 ]; then
        warn "test page submit failed (rc=$rc). Check `lpstat -p` and printer LCD."
        return $rc
    fi
    sleep 3
    local state
    state=$(lpstat -p "$QUEUE_DEFAULT" 2>&1 | head -1)
    say "queue state: $state"
}

main() {
    say "Brother MFC-7860DN Linux setup"
    need_root
    detect_pkg_mgr
    [ -n "$PRINT_IP" ] || auto_detect
    [ -n "$PRINT_IP" ] || die "no printer IP resolved"
    probe_printer
    install_cups
    install_ppd_assets
    choose_ppd
    create_queue "$QUEUE_DEFAULT" \
        "socket://$PRINT_IP:9100" \
        "$PPD_NAME" \
        "Brother MFC-7860DN (PCL XL via pxlmono)"
    # Always register the Brother PostScript PPD as a parallel queue, so the
    # user can opt in without re-running the installer.
    create_queue "$QUEUE_FALLBACK_PS" \
        "ipp://$PRINT_IP/ipp/print" \
        "/usr/share/cups/model/brother-mfc7860dn/BR786N_2.PPD" \
        "Brother MFC-7860DN (BR-Script3 official, IPP)"
    make_default
    test_page || true
    cat <<EOF

  Done.

  Default queue   : $QUEUE_DEFAULT  -> socket://$PRINT_IP:9100  (pxlmono / PCL XL)
  Fallback queue  : $QUEUE_FALLBACK_PS -> ipp://$PRINT_IP/ipp/print   (Brother BR-Script3)

  Quick commands:
    lp file.pdf                                  # print via default
    lp -d $QUEUE_FALLBACK_PS file.pdf            # use Brother PS driver instead
    lpstat -p                                    # check queue state
    sudo cancel $QUEUE_DEFAULT-N                 # cancel job N

  If the printer reports "memory full", you're already on the right queue.
  If you want to swap to the Brother PS driver, see docs/TROUBLESHOOTING.md.
EOF
}

main "$@"