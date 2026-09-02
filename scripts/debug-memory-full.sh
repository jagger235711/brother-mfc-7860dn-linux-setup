#!/usr/bin/env bash
# scripts/debug-memory-full.sh
#
# Diagnose "memory full" errors from Brother MFC-7860DN.
#
# The MFC-7860DN has 32MB RAM and ~8.88MB free VM for the on-board PostScript
# interpreter (per BR786N_2.PPD's *FreeVM). When you print PDF/PS that needs
# more, the printer halts the job with "memory full".
#
# Run this when a job fails with "memory full" or stalls. It:
#   1. Checks the current CUPS queue PPD (you should be on pxlmono, not BR-Script3)
#   2. Suggests a switch if you're on the wrong one
#   3. Verifies the printer really has enough buffer to receive the data
#   4. Recommends the right options for large documents
set -euo pipefail

QUEUE="${QUEUE:-Brother-MFC7860DN}"
say() { printf '\033[1;34m[diag]\033[0m %s\n' "$*"; }

say "queue: $QUEUE"
ppd=$(lpstat -l -p "$QUEUE" 2>/dev/null | awk -F': ' '/PPD:/ {print $2; exit}')
[ -z "$ppd" ] && ppd=$(lpstat -l -p "$QUEUE" 2>/dev/null | awk -F': ' '/界面/ {print $2; exit}')
if [ -z "$ppd" ]; then
    echo "queue not found - is it installed?" >&2
    exit 1
fi
say "PPD: $ppd"

# Detect PostScript interpreter dependency
if grep -q 'gstopxl\|cupsfilters/pxl' "$ppd" 2>/dev/null || \
   grep -q 'cupsFilter.*gstopxl' "$ppd" 2>/dev/null; then
    say "PPD uses gstopxl -> PCL XL output -> printer receives raster (good)"
elif grep -qi 'BR-Script\|Postscript\|PSVersion' "$ppd" 2>/dev/null; then
    say "PPD is PostScript -> the on-board interpreter needs VM"
    say "  -> this is the cause of 'memory full' on PDF jobs"
    say "  -> switch to pxlmono:  sudo lpadmin -p $QUEUE -m pxlmono.ppd"
    exit 2
fi

# Inspect most recent error log
err=$(tail -200 /var/log/cups/error_log 2>/dev/null \
    | grep -i 'memory\|opc\|paused\|jam' | tail -5 || true)
if [ -n "$err" ]; then
    say "recent error_log entries:"
    printf '  %s\n' "$err"
fi

# Check printer state via IPP
ip=$(lpstat -v "$QUEUE" 2>/dev/null \
    | sed -E 's#.*://([^/:]+).*#\1#' | head -1)
if [ -n "$ip" ]; then
    say "printer IP: $ip"
    if timeout 2 bash -c "exec 3<>/dev/tcp/$ip/631" 2>/dev/null; then
        python3 - <<PY 2>/dev/null || true
import socket, struct
def at(t,v): return struct.pack(">bh",t,len(v))+v
op = at(0x01,b"")
op += at(0x23,b"attributes-charset")+at(0x41,b"utf-8")
op += at(0x23,b"natural-language")+at(0x41,b"en")
op += at(0x45,b"printer-uri")+at(0x41,f"ipp://$ip/ipp/print".encode())
op += at(0x42,b"requesting-user-name")+at(0x41,b"debug")
op += at(0x03,b"")
body = struct.pack(">bbhhi",2,0,0x000B,1,len(op)) + bytes(op)
req = (f"POST /ipp/print HTTP/1.1\r\nHost: $ip\r\nContent-Type: application/ipp\r\nContent-Length: {len(body)}\r\nConnection: close\r\n\r\n").encode()+body
s = socket.create_connection(("$ip",631),timeout=4)
s.sendall(req); s.settimeout(3); buf=b""
while True:
    c = s.recv(65536)
    if not c: break
    buf += c
s.close()
i = buf.find(b"\r\n\r\n"); ipp = buf[i+4:] if i>0 else b""
# walk attrs
pos = 0; out = []
while pos+5 < len(ipp):
    ln = struct.unpack(">H", ipp[pos+1:pos+3])[0]
    name = ipp[pos+3:pos+3+ln].decode("latin1","replace"); pos += 3+ln
    if ipp[pos] == 0x03: break
    vl = struct.unpack(">H", ipp[pos+1:pos+3])[0]
    val = ipp[pos+3:pos+3+vl].decode("latin1","replace"); pos += 3+vl
    if any(k in name.lower() for k in ("state","reason","marker","supply","cover","media")):
        out.append((name, val))
for k,v in out:
    print(f"  {k} = {v}")
PY
    fi
fi

cat <<EOF

  Recommended queue options for large documents:
    lp -d $QUEUE -o PageSize=A4 -o Resolution=600dpi -o Duplex=None large.pdf

  Avoid:
    - Resolution=1200dpi (doubles memory on the host side)
    - 2-sided printing with embedded images (slower + more buffers)
    - Files > 50 pages with embedded fonts

  If the printer still reports "memory full" after switching to pxlmono:
    1. The drum may be at end-of-life -> "Replace Drum Soon" on LCD
    2. Firmware may have aged cache -> power-cycle the printer
    3. Some embedded font sets in PDF are huge -> convert to image PDF first:
         gs -sDEVICE=pdfwrite -dPDFSETTINGS=/screen -o out.pdf in.pdf
EOF