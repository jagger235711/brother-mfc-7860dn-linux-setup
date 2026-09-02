# FAQ

## Q: Why pxlmono.ppd and not the Brother PPD?

**A:** The Brother MFC-7860DN has 32 MB of RAM. The PostScript interpreter
on board has only 8.88 MB free VM (declared in the PPD itself, see
`BR786N_2.PPD` line `*FreeVM: "8888000"`). Any non-trivial PDF — embedded
fonts, images, vector paths — pushes that limit and the printer aborts with
"memory full".

`pxlmono` from `cups-filters` tells CUPS to render PDF on the **PC** (via
Ghostscript) to PCL XL raster, then ship raster to the printer. The printer
never has to interpret PostScript, so memory pressure stays low.

The Brother PPD is still installed as the secondary queue
`Brother-MFC7860DN-PS` for users who need Secure Print or Job Hold features.

## Q: Why socket://9100 instead of ipp://631?

**A:** `ipp://` is the "right" protocol and gives you two-way feedback. But
the MFC-7860DN's IPP implementation does not support
`Create-Printer-Subscriptions`, which is what CUPS uses for async status
updates. This causes `lpstat` to report the printer as "disabled" or
"paused" even when it is happily printing.

`socket://` is plain TCP/9100 (HP JetDirect / AppSocket). It is dumb (fire-
and-forget) but the printer receives every byte, and there is no broken
subscription to retry forever.

If you want status, you can run with `ipp://` and accept the noise. See
`docs/TROUBLESHOOTING.md`.

## Q: Will this work on Ubuntu / Debian / Fedora?

**A:** `install.sh` detects the package manager (`apt`, `dnf`, `zypper`,
`pacman`) and uses it. The PPD files are distribution-independent.

The only Arch-specific bit is the systemd unit name (`cups.service`). On
Debian/Ubuntu the service is also `cups`, so this should work.

## Q: The installer says "could not find Brother MFC-7860DN" even though it is on the network.

**A:** The auto-detect falls back to scanning `/24` if `avahi-browse` is
not installed. Install `avahi` first, or pass `--ip <addr>` explicitly.

```bash
# Manjaro / Arch
sudo pacman -S avahi
sudo systemctl enable --now avahi-daemon
sudo ./install.sh --auto
```

## Q: Why isn't there a scanner driver?

**A:** SANE has good Brother backend support via `brscan4`. But scanning is
a separate problem from printing. To enable scanning:

```bash
sudo pacman -S sane brscan4
sudo -E yast2 sane   # or any other SANE configurator
```

The MFC-7860DN exposes a scanner at `ipp://<ip>/ipp/scan` or via the
proprietary `brscan4` driver over `escl:http://<ip>/web/...`.

## Q: How did you find BR786N_2.PPD?

**A:** Brother ships PPDs inside their Windows drivers. The Windows
installer `.exe` is a self-extracting InnoSetup archive. Inside that, the
PostScript driver files are in a `.cab` (one of `data1.cab` or `data2.cab`).
Extract with `7z`, look in
`install/data/Disk1/driver/ps/<arch>/<lang>/BR786N_2.PPD`.

The PPD is fully standard PPD 4.3 / PostScript Level 3 and works on any
platform.

## Q: Is this legal?

**A:** Yes. The Brother PPD is copyrighted but its redistribution for use
with Brother hardware on non-Windows platforms is consistent with how
`foomatic-db` and `OpenPrinting` handle PPD redistribution. Sister projects
like `epson-inkjet-printer-escpr` distribute similar files for non-Linux
printers in AUR/PPAs.

## Q: My Brother printer is a different model (MFC-J6920DW, HL-2270DW, etc.). Can I adapt this?

**A:** Yes. The install script is parameterized by queue name and PPD path.
Just copy the relevant `BR<X>.PPD` from your model's Windows driver and
adjust `install.sh`:

```bash
sudo ./install.sh --ip 192.168.x.y   # uses default queue/ppd paths
```

Or copy the script and edit the queue / PPD constants at the top.

## Q: Can I share this printer over the network?

**A:** Yes, but you need to open CUPS to the LAN. By default it listens on
`127.0.0.1:631`. Edit `/etc/cups/cupsd.conf`:

```
Listen 0.0.0.0:631
<Location />
  Order allow,deny
  Allow from all
</Location>
```

```bash
sudo systemctl restart cups
```

Other machines can then use `ipp://<your-linux-ip>:631/printers/Brother-MFC7860DN`.

Note: this opens your print server to anyone on the LAN. Restrict by
subnet if your network is hostile.