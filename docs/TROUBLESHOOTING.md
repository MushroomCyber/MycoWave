# MycoWave - Troubleshooting Guide

## Quick Diagnostics

```bash
# Run MycoWave verification
sudo ./mycowave-install.sh --dry-run

# Check driver status
lsmod | grep -E '88XXau|rtw88_8812au|8812au|8821au'

# Check interface
ip link show wlan0

# Check monitor mode
sudo airmon-ng check kill
sudo airmon-ng start wlan0
```

---

## Common Issues

### 1. "Module won't load — Required key not available"

**Cause**: Secure Boot enabled, DKMS module not signed.

**Solution**:
```bash
# Option A: Enroll MOK (recommended)
sudo /usr/local/bin/mycowave-enroll-mok full
# Reboot and complete MOK Manager enrollment

# Option B: Disable Secure Boot in BIOS/UEFI
```

### 2. "DKMS build failed" on kernel 6.15+

**Cause**: Kernel API changes (timer, cfg80211, EXTRA_CFLAGS). The Kali
`realtek-rtl88xxau-dkms` package is frozen at 2025-03-30 and cannot build on 6.15+.

**Solution**:
```bash
# 6.15-6.18: use the Ac3rN patched source build (install_alfa_driver.sh)
sudo ./mycowave-install.sh --force-method ac3rn

# Or the managed-mode lwfinger/rtw88 backport (injection NOT guaranteed)
sudo ./mycowave-install.sh --force-method lwfinger

# Or downgrade kernel
sudo apt install linux-image-6.13.0-kali-amd64
```

> `--force-method kali-dkms` is **refused** on kernels `> 6.13` for this reason.
> On `≥ 6.19` (incl. 7.x) **no** maintained out-of-tree rtl8812au driver exists, so
> `ac3rn` cannot be relied on either — the installer defaults to in-kernel `rtw88`
> (`--force-method inkernel`) for managed/monitor use.

### 2b. "Kernel headers are missing" / no build tree

**Cause**: Out-of-tree strategies (`kali-dkms`, `ac3rn`, `aircrack-ng`, `lwfinger`)
require `/lib/modules/$(uname -r)/build`. Kali rolling drops headers for older kernels,
and the `linux-headers-amd64` meta package is deliberately **not** auto-installed because
it pulls a newer kernel image.

**Solution**:
```bash
# Use the in-kernel driver (default on >= 6.19)
sudo ./mycowave-install.sh --force-method inkernel

# If matching headers are actually available for this exact kernel:
sudo apt install linux-headers-$(uname -r)
```

### 3. "Monitor mode fails / interface not created"

**Cause**: NetworkManager/wpa_supplicant holding interface, or no monitor interface was started.

**Solution**:
```bash
# Easiest: the installed helper resolves the adapter, enables monitor mode,
# and prints the real monitor interface (setup is non-destructive).
sudo mycowave-monitor-mode

# Manual equivalent
sudo airmon-ng check kill
sudo airmon-ng start wlan0   # or the stable "awus036ach" symlink
iw dev   # confirm the monitor interface — airmon-ng may keep the same name
iw dev <mon_iface> info | grep monitor
```

Boot-time monitor automation is **opt-in** via `--monitor-service` (it runs
`airmon-ng check kill`, which kills NetworkManager); `--skip-monitor` skips all
monitor automation (symlink rule, helper, dispatcher and service).

### 4. "No 5GHz channels showing"

**Cause**: Regulatory domain restrictions.

**Solution**:
```bash
# Set permissive regulatory domain (Bolivia)
sudo iw reg set BO

# Verify
iw reg get
iw phy phy0 channels | grep 5
```

### 5. "USB disconnects / adapter disappears"

**Cause**: USB autosuspend, power management, or FIQ FSM (Pi).

**Solution**:
```bash
# Check USB power state
cat /sys/bus/usb/devices/*/power/control

# Disable autosuspend for device
echo on | sudo tee /sys/bus/usb/devices/<dev>/power/control
echo -1 | sudo tee /sys/bus/usb/devices/<dev>/power/autosuspend_delay_ms

# On Raspberry Pi - add to /boot/config.txt
echo "max_usb_current=1" | sudo tee -a /boot/config.txt
echo "dwc_otg.fiq_fsm_enable=0" | sudo tee -a /boot/config.txt
```

### 6. "Injection test fails (0%)"

**Cause**: Wrong interface, distance, driver issue — or you are on an `rtw88`-based
strategy (`inkernel`/`lwfinger`), where injection is not guaranteed.

**Solution**:
```bash
# Confirm the monitor interface first — modern airmon-ng may keep the original name
iw dev

# Use the monitor interface (not the managed one) for injection
sudo aireplay-ng -9 <mon_iface>

# Move closer to AP
# Check monitor capability
iw dev <mon_iface> info | grep -i monitor
```

For reliable `airodump-ng`/`aireplay-ng`, use an out-of-tree `88XXau` strategy
(`ac3rn`, `kali-dkms`, or `--force-method aircrack-ng`). In-kernel `rtw88` and the
`lwfinger` backport are managed-mode drivers; see upstream issues #424/#428/#453 and
the kernel ≥ 6.9 channel-pinning bug.

### 7. "arm64/Pi: DKMS build fails — missing headers"

**Cause**: Standard linux-headers don't match Pi kernel.

**Solution**:
```bash
sudo apt update && sudo apt install -y kalipi-kernel-headers

# Then rebuild
sudo dkms autoinstall -k $(uname -r)
```

### 8. "Driver conflict: both DKMS and in-kernel loaded"

**Cause**: Both 88XXau and rtw88_8812au trying to bind device.

**Solution**:
```bash
# Check which is loaded
lsmod | grep -E '88XXau|rtw88_8812au'

# Unload unwanted, load desired
sudo modprobe -r 88XXau
sudo modprobe rtw88_8812au

# Or let MycoWave fix it
sudo ./mycowave-install.sh  # Re-runs conflict resolution
```

### 9. "Firmware crash / TX hang in dmesg"

**Cause**: Firmware bug, thermal issue, or USB signal quality.

**Solution**:
```bash
# Update firmware
sudo apt update && sudo apt install -y linux-firmware
sudo cp /lib/firmware/rtw88* /lib/firmware/rtlwifi/ 2>/dev/null

# Check thermal
cat /sys/kernel/debug/rtw88/phy*/thermal

# Enable thermal protection (in modprobe.d)
options 88XXau rtw_tx_pwr_track=1 rtw_thermal_protect=1
```

### 10. "Low throughput / packet loss"

**Cause**: USB 2.0 bottleneck, interference, or power save.

**Solution**:
```bash
# Disable power save
sudo iw dev wlan0 set power_save off

# Check link quality
iw dev wlan0 link

# Force USB 2.0 (if on USB3 port causing interference)
echo 2 | sudo tee /sys/module/88XXau/parameters/rtw_switch_usb_mode
```

### 11. "Adapter disappears after a failed out-of-tree install"

**Cause**: A previous out-of-tree install left the in-kernel `rtw88` driver blacklisted.

**Solution**: Out-of-tree installs now build first and only blacklist on success, rolling
back any `blacklist rtw_` config on failure. If the adapter is still missing:
```bash
# Clear the stale blacklist and rebuild initramfs
sudo rm -f /etc/modprobe.d/blacklist-rtw88.conf && sudo update-initramfs -u

# Or restore the in-kernel driver
sudo ./mycowave-install.sh --force-method inkernel
# Reboot recommended
```

---

## Raspberry Pi Specific

| Issue | Fix |
|-------|-----|
| Adapter not detected | `max_usb_current=1` in `/boot/config.txt` |
| Random disconnects | `dwc_otg.fiq_fsm_enable=0` in `/boot/config.txt` |
| DKMS build fails | `apt install kalipi-kernel-headers` |
| High CPU during capture | `echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor` |
| Voltage warning (⚡) | Use powered USB hub; Pi USB limited to 1.2A total |

---

## Kernel Version Matrix

| Kernel | Auto Strategy | Reliable Injection | Notes |
|--------|---------------|--------------------|-------|
| ≥ 6.19 (incl. 7.x) | `inkernel` | None guaranteed | No maintained out-of-tree driver; `rtw88` is managed/monitor only |
| 6.15–6.18 | `ac3rn` | `ac3rn` / `aircrack-ng` | `kali-dkms` does not build here; `ac3rn` is a source build |
| 6.14 | `inkernel` | `kali-dkms`* / `aircrack-ng` | `rtw88` managed only |
| 6.6–6.13 | `kali-dkms` | `kali-dkms` / `aircrack-ng` | Kali package hard-gated to ≤ 6.13 |
| < 6.6 | `lwfinger` | `aircrack-ng` | lwfinger is managed-mode only |

*`kali-dkms` on 6.14 is force-only (`--force-method kali-dkms`).
In-kernel `rtw88` and `lwfinger` are reliable in managed mode but **not** for
`airodump-ng`/`aireplay-ng` injection.

---

## Debug Commands

```bash
# Full driver info
modinfo 88XXau
modinfo rtw88_8812au

# Kernel messages (WiFi only)
dmesg -T | grep -iE "rtw|8812|8821|wlan|firmware"

# Module parameters
for p in /sys/module/88XXau/parameters/*; do echo "$p: $(cat $p)"; done

# USB device tree
lsusb -t

# Regulatory domain
iw reg get

# Channel list
iw phy phy0 channels

# Monitor mode interfaces
iw dev

# NetworkManager status
nmcli device status

# DKMS status
dkms status

# Secure Boot
mokutil --sb-state
mokutil --list-enrolled
```

---

## Log Files

| Log | Location |
|-----|----------|
| MycoWave install | `/var/log/mycowave-install.log` |
| Watchdog | `journalctl -u mycowave-watchdog -f` |
| Thermal | `journalctl -u mycowave-thermal -f` |
| Crash dumps | `/var/log/mycowave-crashes/` |
| Kernel | `dmesg -T` / `journalctl -k` |

---

## Getting Help

1. **Run verification**: `sudo ./mycowave-install.sh --dry-run`
2. **Collect crash dump**: `sudo /usr/local/bin/mycowave-collect-crash`
3. **Check GitHub Issues**: https://github.com/MushroomCyber/MycoWave/issues
4. **Include in bug report**:
   - `uname -r`
   - `lsmod | grep -E '88XX|rtw'`
   - `dmesg -T | grep -iE 'rtw|8812|8821|wlan' | tail -50`
   - Output of `sudo ./mycowave-install.sh --dry-run`

---

## Recovery Commands

The interactive setup menu only appears when the installer is run with no arguments on a real terminal (it needs a
TTY, so piped/CI or non-TTY runs never prompt). Pass any flags or add `--no-menu` for scripted, non-interactive
installs; `--dry-run --menu` stays side-effect free.

```bash
# Complete reset
sudo ./mycowave-install.sh --uninstall
sudo reboot
sudo ./mycowave-install.sh --performance --secure-boot --watchdog --thermal

# Force a specific strategy (ac3rn is 6.15-6.18 only; use inkernel on >= 6.19)
sudo ./mycowave-install.sh --force-method ac3rn
sudo ./mycowave-install.sh --force-method inkernel

# Re-sign modules after kernel update
sudo /usr/local/bin/mycowave-enroll-mok sign

# Manual monitor mode (or just run: sudo mycowave-monitor-mode)
sudo airmon-ng check kill
sudo airmon-ng start wlan0
iw dev   # note the interface in monitor mode (airmon-ng may keep wlan0)
sudo airodump-ng <mon_iface>
```