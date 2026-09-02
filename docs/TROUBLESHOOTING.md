# Troubleshooting

## "Memory full" / "内存已满"

This is the most common issue. The MFC-7860DN only has 32 MB RAM, with
~8.88 MB usable as PostScript interpreter VM. PDF jobs with embedded fonts
or large images routinely exceed this.

### Verify you are on the right queue

```bash
lpstat -p Brother-MFC7860DN -l | grep -i 'interface\|ppd'
```

You should see `/usr/share/cups/model/brother-mfc7860dn/pxlmono.ppd` or
`/usr/share/ppd/cupsfilters/pxlmono.ppd`.

If you see `BR786N_2.PPD`, you are on the wrong queue:

```bash
sudo lpadmin -p Brother-MFC7860DN -m pxlmono.ppd
```

### Run the diagnostic

```bash
sudo ./scripts/debug-memory-full.sh
```

It checks the active PPD, reads recent CUPS errors, queries IPP
`printer-state-reasons`, and prints recommended options.

### Heavy PDF workaround

If even pxlmono runs out of memory (rare), rasterize on the host first:

```bash
gs -sDEVICE=pdfwrite -dPDFSETTINGS=/screen -o light.pdf input.pdf
lp light.pdf
```

`/screen` produces ~72 DPI images — small enough that the printer can hold
the entire raster in buffer.

---

## Deep sleep / 深度睡眠

Brother printers enter deep sleep after ~5 min of idle. In deep sleep:

- The printer still responds to TCP SYN on 631 / 9100 (TCP open succeeds),
  but does not process any data.
- `wol` / `etherwake` magic packets rarely wake a Brother (WoL is not
  enabled by default on the 7860DN).

**Fix:** walk to the printer and press any button. After ~5 s it is online.
Re-submit the job:

```bash
sudo lpadmin -p Brother-MFC7860DN -E
sudo cupsenable Brother-MFC7860DN
lp file.pdf
```

If you print often, disable deep sleep from the printer's panel:
`Settings > General > Sleep > Off`.

---

## "paused" / `opc-life-over-warning`

The MFC-7860DN pauses itself when:

- `opc-life-over-warning` — drum is near end of life. Still prints; just a
  warning. Ignore unless it becomes `opc-life-over`.
- `media-empty` — paper tray empty.
- `media-jam` — paper jam.
- `cover-open` — front cover not latched.

To clear the paused state after you've physically resolved it:

```bash
sudo lpadmin -p Brother-MFC7860DN -E
sudo cupsenable Brother-MFC7860DN
```

The printer's IPP `printer-state-reasons` updates within a few seconds.

### Drum end-of-life

Drum part number: **DR-2250** (or compatible). Expected life: ~12 000
pages. After end-of-life the printer may refuse jobs.

To check current drum life from the panel:

`Settings > Machine Info > Drum Life`

Or via IPP, look at `printer-supply-info-current` or
`printer-marker-supply-level`.

---

## "Cannot get printer state" in error_log

CUPS tries to subscribe to IPP notifications (`Create-Printer-Subscriptions`)
to receive `printer-state-changed` events. The MFC-7860DN firmware does not
implement this.

**Not an actual error.** Jobs still complete. To silence the noise:

```bash
sudo lpadmin -p Brother-MFC7860DN -o printer-error-policy=abort-job
```

This makes CUPS give up after one failed status poll instead of retrying
forever.

---

## Wrong IP address

Symptoms:

- `lpstat -p` shows the printer as `disabled`
- All CUPS log lines show "connection refused"
- `ping` returns `Destination host unreachable` from a `192.168.x.x`
  router message

Fix:

```bash
sudo lpadmin -p Brother-MFC7860DN -v "socket://<correct-ip>:9100"
sudo lpadmin -p Brother-MFC7860DN -E
```

To find the current IP from the panel: `Settings > Network > WLAN/LAN > TCP/IP`.

---

## socket://9100 vs ipp://631

| Use case | URI |
|---|---|
| Speed, low memory | `socket://<ip>:9100` |
| Status / job feedback | `ipp://<ip>/ipp/print` |

Both work. `socket://` does not give CUPS any feedback that the job
finished — `lpstat` stays in "printing" until the next job. That's a
display quirk, not an actual problem.

---

## PPD options not visible in print dialog

If `lpoptions -p Brother-MFC7860DN -l` returns nothing useful, the PPD
file may be malformed or in the wrong directory:

```bash
sudo ls -l /usr/share/cups/model/brother-mfc7860dn/
sudo systemctl restart cups
sudo lpadmin -p Brother-MFC7860DN -m /usr/share/cups/model/brother-mfc7860dn/pxlmono.ppd
```

---

## OKular / LibreOffice ignores CUPS defaults

Some GTK / Qt apps cache the printer list. After changing the queue:

```bash
sudo systemctl restart cups
# log out and / log in, or:
dbus-send --session --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.ReloadConfig >/dev/null 2>&1 || true
```

Then re-open the print dialog.