# Brother MFC-7860DN Linux Setup

Sets up a working CUPS print queue for the Brother MFC-7860DN on Linux.

This exists because:

1. Brother never published an official Linux driver for the MFC-7860DN.
2. `manjaro` / `arch` ships `foomatic` PPDs for similar models but none for the
   7860DN.
3. Using the wrong PPD (BR-Script3 generic, or the wrong foo filter) makes the
   printer report **"memory full"** on any non-trivial PDF.
4. The official Windows driver (which works fine) hides a `BR786N_2.PPD` that
   is genuinely cross-platform — but extracting and installing it on Linux is
   not documented anywhere.

This repo solves all three.

## Why the printer says "memory full"

The MFC-7860DN has **32 MB of RAM total**, of which only **~8.88 MB** is free
for the on-board PostScript interpreter (`*FreeVM` in `BR786N_2.PPD`). When
you send it a PDF with embedded fonts or images, the PS interpreter runs out
of VM and aborts the job.

`pxlmono` is a generic PPD that ships with `cups-filters`. It tells CUPS to
render PostScript/PDF on the **PC** to PCL XL (PCL6) raster and ship the
raster to the printer. The printer does no PostScript interpretation, so the
32 MB / 8.88 MB limit never matters.

This is what `install.sh` defaults to.

The Brother official `BR786N_2.PPD` is installed as a parallel queue
(`Brother-MFC7860DN-PS`) for users who specifically need features the
`pxlmono` PPD does not expose (Secure Print / Job Hold / Password).

## Install

```bash
git clone https://github.com/<you>/brother-mfc-7860dn-linux-setup.git
cd brother-mfc-7860dn-linux-setup
sudo ./install.sh --ip 192.168.x.y
```

Or, if you don't know the printer's IP:

```bash
sudo ./install.sh --auto
```

The script will:

1. Detect your package manager (pacman / apt / dnf / zypper).
2. Install `cups`, `cups-filters`, `ghostscript` if missing.
3. Enable and start `cups.service`.
4. Probe the printer on TCP 631 / 9100 / 515 / 80.
5. Copy the official Brother PPD into `/usr/share/cups/model/brother-mfc7860dn/`.
6. Create two queues:
   - `Brother-MFC7860DN` — `socket://IP:9100` + `pxlmono.ppd` (default, fast, low memory)
   - `Brother-MFC7860DN-PS` — `ipp://IP/ipp/print` + `BR786N_2.PPD` (Brother official, falls back to PS)
7. Send a test page.

## Usage

```bash
lp file.pdf                              # default queue (pxlmono)
lp -d Brother-MFC7860DN-PS file.pdf      # Brother PostScript driver
lp -d Brother-MFC7860DN -o PageSize=A4 -o Resolution=600dpi file.pdf
lpstat -p                                # check queue
sudo cancel Brother-MFC7860DN-3          # cancel job 3
```

## Helper scripts

- `scripts/detect-printer.sh` — find the printer without knowing its IP
- `scripts/test-print.sh QUEUE` — send a quick test page
- `scripts/debug-memory-full.sh` — diagnose "memory full" errors

## Troubleshooting

See [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md).

Short version:

| Symptom | Likely cause | Fix |
|---|---|---|
| "Memory full" on PDF | BR-Script3 interpreter ran out of VM | Switch to `Brother-MFC7860DN` (pxlmono) queue |
| Job submits but nothing prints | Printer is in deep sleep | Press a button on the printer to wake |
| Queue stuck in "printing" | `socket://` doesn't get IPP callbacks | It's a CUPS display quirk; job did complete |
| `lpstat` shows `paused` | OPC drum life ended | Replace drum unit (DR-2250) |

## What this repo contains

```
.
├── install.sh                          # main installer
├── uninstall.sh                        # remove queues + PPD files
├── ppd/
│   ├── BR786N_2.PPD                    # Brother official PostScript PPD (extracted from Windows driver)
│   └── BR7860_2.PPD                    # MFC-7860DW sibling PPD (identical, kept for reference)
├── scripts/
│   ├── detect-printer.sh               # mDNS / ARP / subnet scan
│   ├── test-print.sh                   # send + watch test page
│   └── debug-memory-full.sh            # diagnose "memory full" errors
├── docs/
│   ├── TROUBLESHOOTING.md
│   └── FAQ.md
└── README.md
```

## Provenance

`BR786N_2.PPD` is extracted from the official Brother Windows driver:

> `MFC-7860DN-inst-D1-CHN.EXE` → `install/data/Disk1/data1.cab` → `BR786N_2.PPD`

Copyright (C) 2010 Brother Industries, Ltd.

Brother does not publish this PPD on their Linux download portal (the only
links to it are in the Windows installer). Distributing the extracted PPD
for Linux use is consistent with how `foomatic` handles PPD redistribution
under the GPL.

## License

- The `BR786N_2.PPD` and `BR7860_2.PPD` files remain Copyright Brother Industries, Ltd.
- All scripts (`install.sh`, `uninstall.sh`, `scripts/`) are MIT licensed.
- `docs/` is CC-BY-SA 4.0.

## See also

- [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) — memory full, deep sleep, OPC drum
- [`docs/FAQ.md`](docs/FAQ.md)