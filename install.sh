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

# Multi-copy fix.
#
# cupsd passes the job copy count as argv[4] and strips `copies` out of the
# options string (argv[5]). pdftopdf inside libcupsfilters <= 2.2.1 only
# honours a `copies=N` key that is present in the options string - the
# argv[4] -> data->copies fallback exists only in upstream master - so
# `lp -n 3` printed exactly one copy, silently. Both of this repo's queues
# start their filter chain with the `universal` filter (cups-filters 2.x),
# so wrapping `universal` to re-inject argv[4] into the options string fixes
# it for both queues. See filters/copies-fix.sh for details.
#
# Idempotent: skips if already installed, and refreshes universal.real when
# a cups-filters package upgrade has replaced the wrapper with the ELF again.
install_copies_fix() {
    local src_dir marker="brother-mfc-7860dn-copies-fix"
    local filter_dir="" serverbin d
    src_dir=$(cd "$(dirname "$0")" && pwd)

    # Locate the CUPS filter dir: Arch/Debian use /usr/lib/cups,
    # Fedora/RHEL use /usr/libexec/cups. Ask cups-config first.
    local -a candidates=()
    if command -v cups-config >/dev/null 2>&1; then
        serverbin=$(cups-config --serverbin 2>/dev/null || true)
        [ -n "$serverbin" ] && candidates+=("$serverbin/filter")
    fi
    candidates+=(/usr/lib/cups/filter /usr/libexec/cups/filter)
    for d in "${candidates[@]}"; do
        if [ -x "$d/universal" ] || [ -f "$d/universal.real" ]; then
            filter_dir="$d"
            break
        fi
    done
    if [ -z "$filter_dir" ]; then
        warn "universal filter not found - multi-copy fix skipped (needs cups-filters 2.x)"
        return 0
    fi

    if [ -f "$filter_dir/universal" ] && grep -q "$marker" "$filter_dir/universal" 2>/dev/null; then
        say "multi-copy fix already installed in $filter_dir"
        return 0
    fi

    # Keep (or refresh) the distro binary as universal.real. A cups-filters
    # upgrade overwrites our wrapper with the ELF, so this also reinstalls
    # the fix transparently.
    if [ -f "$filter_dir/universal" ]; then
        say "saving original universal filter -> $filter_dir/universal.real"
        cp -f "$filter_dir/universal" "$filter_dir/universal.real"
    fi
    if [ ! -x "$filter_dir/universal.real" ]; then
        warn "no universal binary to wrap - multi-copy fix skipped"
        return 0
    fi
    install -m 0755 "$src_dir/filters/copies-fix.sh" "$filter_dir/universal"
    say "multi-copy fix installed: lp -n N now prints N copies"
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
    case "${FORCE_PPD:-}" in
        ""|pxlmono|pxl) PPD_NAME="";;   # pxlmono, resolved to a file path below
        brother|br)     PPD_NAME="/usr/share/cups/model/brother-mfc7860dn/BR786N_2.PPD";;
        *)              die "unknown --ppd value: $FORCE_PPD";;
    esac
    if [ -z "$PPD_NAME" ]; then
        # Always resolve pxlmono to a PPD *file*. CUPS 2.4 removed the
        # cups-driverd model database lookup for drivers, so model names like
        # "everywhere.pxlmono" no longer resolve and lpadmin aborts with
        # "cups-driverd failed to get PPD file".
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
    # CUPS 2.4+ deprecated `-m` for driver PPDs (cups-driverd resolves the name
    # relative to /usr/share/cups/model and rejects absolute paths, producing
    # "cups-driverd failed to get PPD file"). Use `-P <file>` for a PPD path and
    # `-m <model>` only for a cups-driverd model name like everywhere.pxlmono.
    local ppd_flag="-P"
    case "$ppd" in
        */*) ppd_flag="-P";;
        *)   ppd_flag="-m";;
    esac
    lpadmin -p "$queue" -E \
        -v "$uri" \
        "$ppd_flag" "$ppd" \
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
    install_copies_fix
    choose_ppd
    create_queue "$QUEUE_DEFAULT" \
        "socket://$PRINT_IP:9100" \
        "$PPD_NAME" \
        "Brother MFC-7860DN (PCL XL via pxlmono)"
    # The generic pxlmono PPD ships with *DefaultOptionDuplex: False (duplexer
    # "Not Installed"). Combined with "*UIConstraints: *Duplex *OptionDuplex
    # False" every libcups client (GTK, Chromium, LibreOffice) sees
    # "Double-Sided Printing" as a conflicting choice and silently sends
    # simplex (Duplex=None, sides=one-sided) - the user's duplex selection is
    # reverted with no error. The MFC-7860DN duplex unit is real; declare it so
    # the option survives client-side conflict resolution.
    lpadmin -p "$QUEUE_DEFAULT" -o OptionDuplex=True >/dev/null
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