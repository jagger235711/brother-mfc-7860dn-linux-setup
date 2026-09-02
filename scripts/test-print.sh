#!/usr/bin/env bash
# scripts/test-print.sh
#
# Send a small test page to the queue and report what happened.
# Used by install.sh post-flight, but also useful as a manual sanity check.
set -euo pipefail

QUEUE="${1:-Brother-MFC7860DN}"

tmp=$(mktemp --suffix=.ps)
trap 'rm -f "$tmp"' EXIT
cat > "$tmp" <<'EOF'
%!PS-Adobe-3.0
%%BoundingBox: 0 0 595 842
%%EndComments
%%Page: 1 1
/Times-Roman findfont 18 scalefont setfont
72 760 moveto (Brother MFC-7860DN - test page) show
72 720 moveto (Queue: Brother-MFC7860DN) show
72 680 moveto (If you can read this, the queue is alive.) show
showpage
%%EOF
EOF

echo "[test] queue: $QUEUE"
echo "[test] submit..."
lp -d "$QUEUE" -o PageSize=A4 "$tmp"
echo "[test] submitted. Watching queue for 5s..."
for _ in 1 2 3 4 5; do
    state=$(lpstat -p "$QUEUE" 2>&1 | head -1)
    echo "[test] $state"
    echo "$state" | grep -qE '(空闲|idle)' && break
    sleep 1
done
echo "[test] access_log tail:"
tail -1 /var/log/cups/access_log
echo "[test] error_log tail:"
tail -1 /var/log/cups/error_log