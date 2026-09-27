#!/usr/bin/env bash
# uninstall.sh - remove the Brother MFC-7860DN queues created by install.sh
#
# Removes:
#   - queue: Brother-MFC7860DN
#   - queue: Brother-MFC7860DN-PS
#   - ppd files at /usr/share/cups/model/brother-mfc7860dn/
#   - the multi-copy wrapper filter (restores universal.real if present)
#
# Does NOT remove CUPS itself - that's a system package.
# Does NOT stop cups.service.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "must run as root: sudo $0" >&2
    exit 1
fi

for q in Brother-MFC7860DN Brother-MFC7860DN-PS; do
    if lpstat -p "$q" >/dev/null 2>&1; then
        echo "removing queue $q"
        lpadmin -x "$q" || true
    else
        echo "queue $q not present"
    fi
done

if [ -d /usr/share/cups/model/brother-mfc7860dn ]; then
    echo "removing /usr/share/cups/model/brother-mfc7860dn/"
    rm -rf /usr/share/cups/model/brother-mfc7860dn
fi

# restore the original `universal` filter if our multi-copy wrapper is active
for filter_dir in /usr/lib/cups/filter /usr/libexec/cups/filter; do
    if [ -f "$filter_dir/universal" ] && grep -q "brother-mfc-7860dn-copies-fix" "$filter_dir/universal" 2>/dev/null; then
        if [ -f "$filter_dir/universal.real" ]; then
            echo "restoring original $filter_dir/universal"
            mv -f "$filter_dir/universal.real" "$filter_dir/universal"
        else
            echo "warning: $filter_dir/universal.real missing, leaving wrapper in place" >&2
        fi
    fi
done

# clear default printer if it pointed at our queues
current_default=$(lpstat -d 2>/dev/null | awk '{print $NF}')
if [ "$current_default" = "Brother-MFC7860DN" ] || [ "$current_default" = "Brother-MFC7860DN-PS" ]; then
    echo "clearing default printer"
    lpadmin -d "" || true
fi

systemctl restart cups 2>/dev/null || true
echo "done."