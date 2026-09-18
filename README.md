# MycoWave

> **Smart installer for Alpha AWUS036ACH Wi-Fi adapter on Kali Linux**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Shell: Bash](https://img.shields.io/badge/Shell-Bash-green.svg)](mycowave-install.sh)
[![Kali: 2024.x-2026.1+](https://img.shields.io/badge/Kali-2024.x%20-%202026.1+-blue.svg)](https://www.kali.org/)

---

## Overview

MycoWave is a version-aware, zero-intervention installer for the **Alpha AWUS036ACH** (RTL8812AU/RTL8821AU chipset) on Kali Linux. It automatically detects your kernel version, architecture, and Secure Boot state, then selects a driver strategy from five disjoint ranges — `lwfinger/rtw88` on kernels `< 6.6`, Kali DKMS on 6.6–6.13, the Ac3rN patched source build on 6.15–6.18, and in-kernel `rtw88` on 6.14 and `≥ 6.19`. `ac3rn` and `aircrack-ng` remain available on demand via `--force-method`.

**No more manual `make`, `dkms`, or `airmon-ng` fiddling.** Plug in the adapter, run MycoWave, and you're capturing packets.

---

## Features

| Feature | Description |
|---------|-------------|
| **Auto-detection** | Kernel (6.6–7.x), arch (x86_64/ARM64), Secure Boot, Kali version |
| **Smart strategy selection** | Disjoint ranges: `lwfinger` < 6.6, Kali DKMS 6.6–6.13, in-kernel `rtw88` on 6.14 and ≥ 6.19, Ac3rN source build 6.15–6.18 |
| **Managed vs injection** | Out-of-tree `88XXau` (ac3rn/kali-dkms/aircrack-ng) for reliable injection; in-kernel `rtw88`/`lwfinger` for managed use |
| **Driver conflict resolution** | Auto-blacklists competing drivers (DKMS vs in-kernel) |
| **Monitor mode automation** | udev rules + NetworkManager dispatcher + systemd service |
| **Performance optimizations** | `--performance` flag: USB2 force, powersave disable, TX power max, 5GHz unlock |
| **Firmware updates** | Auto-copies latest `rtw88xx_fw.bin` from `linux-firmware` |
| **DKMS auto-rebuild** | Initramfs hook + systemd service for kernel upgrades |
| **Post-install verification** | Module load, monitor mode, injection capability, 5GHz channels |
| **Comprehensive test suite** | `--test` flag: 20 checks incl. a real `aireplay-ng -9` injection test, ending with a `managed: OK\|FAILED \| injection: OK\|FAILED\|SKIPPED` summary |
| **Clean uninstall** | `--uninstall` is manifest-driven (`/var/lib/mycowave/installed.files`) — removes only MycoWave-created files; `--remove-mok` also deletes MOK keys |
| **ARM64/Pi support** | Auto-installs `kalipi-kernel-headers`, USB power tweaks |
| **Secure Boot (MOK)** | `--secure-boot`: key gen, UEFI enrollment, DKMS signing (signing config persisted for kernel-upgrade rebuilds) |
| **Self-healing watchdog** | `--watchdog`: health checks, USB reset, driver reload, crash detection |
| **Thermal monitoring** | `--thermal`: TX power throttling at 80°C, critical at 95°C |
| **Bluetooth coexistence** | `--coex`: auto-detects internal BT and writes an active `rtw88_core rtw_btcoex_enable=<0\|1>` line for `inkernel`/`lwfinger` |
| **Crash dump collector** | Auto-installs hourly diagnostic collection (kernel logs, debugfs, USB, etc.) |

---

## Quick Start

```bash
# Clone and run
git clone https://github.com/your-org/MycoWave.git
cd MycoWave
chmod +x mycowave-install.sh

# Standard install (auto-detects everything)
sudo ./mycowave-install.sh

# With performance optimizations (recommended)
sudo ./mycowave-install.sh --performance

# Preview what would happen
sudo ./mycowave-install.sh --dry-run

# Force a specific strategy (e.g. managed-mode rtw88 backport)
sudo ./mycowave-install.sh --force-method lwfinger
```

After install, just **plug in the AWUS036ACH** — monitor mode starts automatically on `wlan0mon`.

---

## Installation Methods by Kernel

| Kernel Version | Strategy | Driver |
|----------------|----------|--------|
| **≥ 6.19** (incl. 7.x) | `inkernel` | In-kernel `rtw88_8812au` (mac80211). No maintained out-of-tree rtl8812au driver supports 6.19+/7.x, and Kali rolling drops headers for older kernels so a DKMS build is not possible. Managed + monitor mode; injection not guaranteed |
| **6.15 – 6.18** | `ac3rn` | Ac3rN patched **source build** (`install_alfa_driver.sh`; supports only 6.15/6.16/6.18) |
| **6.14** | `inkernel` | In-kernel `rtw88_8812au` (mac80211) |
| **6.6 – 6.13** | `kali-dkms` | Kali `realtek-rtl88xxau-dkms` package (frozen at 2025-03-30; hard-gated to ≤ 6.13) |
| **< 6.6** | `lwfinger` | `lwfinger/rtw88` DKMS backport (managed mode; injection NOT guaranteed) |

`ac3rn` and `aircrack-ng` are **not selected automatically** — they remain available only
via `--force-method`. Forcing `kali-dkms` on a kernel `> 6.13` is refused, because the
frozen Kali package does not build on 6.15+.

All out-of-tree strategies (`kali-dkms`, `ac3rn`, `aircrack-ng`, `lwfinger`) require the
build tree `/lib/modules/$(uname -r)/build`. If it is missing, the installer aborts the
out-of-tree strategy early and points to `--force-method inkernel`. The
`linux-headers-amd64` meta package is deliberately **not** auto-installed — it pulls a
newer kernel image.

Force a specific method:
```bash
sudo ./mycowave-install.sh --force-method ac3rn
sudo ./mycowave-install.sh --force-method lwfinger  # managed-mode rtw88 backport
```

### Managed mode vs injection

The in-kernel `rtw88` stack (and the `lwfinger/rtw88` backport) works well in **managed
mode**, but **packet injection is unreliable** — see upstream issues
[#424](https://github.com/lwfinger/rtw88/issues/424)/[#428](https://github.com/lwfinger/rtw88/issues/428)/[#453](https://github.com/lwfinger/rtw88/issues/453)
and a channel-pinning regression on kernels ≥ 6.9. This is why kernels ≥ 6.19 default to
`inkernel` for managed/monitor use: no out-of-tree driver can be built there. For
dependable `airodump-ng` / `aireplay-ng` captures, use an out-of-tree `88XXau` strategy
(`ac3rn`, `kali-dkms`, or `aircrack-ng`) where one is available.

Out-of-tree installs build the module **first** and only blacklist the in-kernel driver
after a successful build. If the build fails, MycoWave removes any
`/etc/modprobe.d/*.conf` containing `blacklist rtw_` and runs `update-initramfs -u`, so
the working in-kernel driver is never left blacklisted.

---

## Options

```bash
sudo ./mycowave-install.sh [OPTIONS]

Options:
  --dry-run              Show what would be done without making changes
  --verbose, -v          Verbose output
  --uninstall            Remove driver and all configuration (manifest-driven)
  --force-method METHOD  Force install method: inkernel|lwfinger|kali-dkms|ac3rn|aircrack-ng
                         (kali-dkms is refused on kernels > 6.13)
  --skip-verify          Skip post-install verification
  --skip-monitor         Skip automatic monitor mode setup
  --reg-domain CODE      Regulatory domain for 5GHz (default: BO)
  --performance          Enable performance optimizations
  --skip-firmware        Skip firmware update check
  --secure-boot          Enable Secure Boot MOK automation
  --pi-optimizations     Enable Raspberry Pi / ARM64 optimizations
  --watchdog             Enable self-healing watchdog service
  --thermal              Enable thermal monitoring service
  --coex                 Configure Bluetooth coexistence
  --skip-crash-collector Skip crash dump collector installation
  --test                 Run comprehensive test suite after install (includes real
                         aireplay-ng -9 injection check; implies --skip-verify)
  --remove-mok           Also delete MOK keys on --uninstall (UEFI enrollment remains)
  --help, -h             Show this help
```

---

## Performance Optimizations (`--performance`)

Applies a tuned `/etc/modprobe.d/awus036ach-performance.conf`:

```bash
# Force USB 2.0 mode (avoids 2.4GHz interference, stable)
rtw_switch_usb_mode=2

# Disable power save (prevents monitor mode drops)
rtw_ips_mode=0 rtw_lps_level=0

# Max TX power (where supported by fork)
rtw_tx_pwr_idx_override=30

# Monitor mode: disable 1Mbps default, retransmit injected frames
rtw_monitor_disable_1m=1 rtw_monitor_retransmit=1

# Regulatory domain: Bolivia (full 5GHz, high power)
rtw_country_code=BO
```

---

## What Gets Installed

```
├── /etc/modprobe.d/
│   ├── blacklist-rtl88xxau.conf      # Or blacklist-rtw88.conf
│   ├── awus036ach-performance.conf   # (with --performance)
├── /etc/udev/rules.d/
│   └── 90-awus036ach.rules           # Consistent wlan0 naming
├── /etc/NetworkManager/dispatcher.d/
│   └── 99-awus036ach-monitor         # Auto monitor on plug
├── /etc/systemd/system/
│   └── awus036ach-monitor.service    # Boot-time monitor mode
├── /etc/initramfs-tools/scripts/init-top/
│   └── awus036ach                     # Early driver load
├── /lib/firmware/rtlwifi/
│   └── rtw88xx_fw.bin                 # Latest firmware
└── /var/log/mycowave-install.log      # Install log
```

---

## Post-Install Usage

```bash
# Manual monitor mode (if auto didn't trigger)
sudo airmon-ng check kill
sudo airmon-ng start wlan0

# Packet capture
sudo airodump-ng wlan0mon

# Injection test
sudo aireplay-ng -9 wlan0mon

# Check 5GHz channels
iw phy phy0 channels | grep -A1 "5[0-9][0-9][0-9]"
```

> On `inkernel`/`lwfinger` (rtw88) the adapter works in managed mode, but injection is
> unreliable — use an out-of-tree `88XXau` strategy for capture/injection workloads.

---

## Uninstall

```bash
# Removes only files recorded in /var/lib/mycowave/installed.files
sudo ./mycowave-install.sh --uninstall
# Reboot recommended

# Also delete the MOK key pair (UEFI enrollment still remains)
sudo ./mycowave-install.sh --uninstall --remove-mok
```

---

## Requirements

- Kali Linux 2024.x – 2026.1+ (or Debian-based with kernel 6.6+)
- Root/sudo access
- Internet connection (for packages/firmware)
- Kernel build tree for out-of-tree strategies: `/lib/modules/$(uname -r)/build`
  (the `linux-headers-amd64` meta package is **not** auto-installed — it pulls a newer
  kernel image). Kernels ≥ 6.19 fall back to in-kernel `rtw88` when headers are absent.

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| **Module won't load (Secure Boot)** | Run `mokutil --import` with generated MOK key, enroll on reboot |
| **DKMS build fails on kernel 6.15+** | Use `--force-method ac3rn` (6.15–6.18) or `--force-method lwfinger` (managed) |
| **No headers/build tree (`/lib/modules/$(uname -r)/build`)** | Out-of-tree DKMS cannot build — use `--force-method inkernel` (default on ≥ 6.19) |
| **Adapter disappears after a failed install** | The rollback should have cleared the blacklist; if not: `sudo rm -f /etc/modprobe.d/blacklist-rtw88.conf && sudo update-initramfs -u`, then `sudo ./mycowave-install.sh --force-method inkernel` |
| **`--force-method kali-dkms` refused** | The frozen Kali package only builds ≤ 6.13; use `inkernel`/`ac3rn`/`lwfinger` instead |
| **`rtw88` injection unreliable** | Expected: use an out-of-tree `88XXau` strategy (`ac3rn`/`kali-dkms`/`aircrack-ng`) |
| **Monitor mode fails** | Run `sudo airmon-ng check kill` first |
| **No 5GHz channels** | `sudo iw reg set BO` (or your country code) |
| **ARM64/Pi build fails** | Ensure `kalipi-kernel-headers` installed |
| **USB disconnects** | Add `dwc_otg.fiq_fsm_enable=0` to `/boot/config.txt` (Pi) |

---

## Project Structure

```
MycoWave/
├── mycowave-install.sh      # Main installer script
├── README.md                # This file
├── LICENSE                  # MIT License
├── docs/
│   ├── STRATEGIES.md        # Driver strategy details
│   ├── PERFORMANCE.md       # Performance tuning guide
│   ├── SECURE_BOOT.md       # Secure Boot/MOK guide
│   └── TROUBLESHOOTING.md   # Common issues
└── scripts/
    ├── enroll-mok.sh        # MOK enrollment helper
    ├── wifi-watchdog.sh     # Self-healing watchdog
    └── collect-crash.sh     # Debug crash dump collector
```

---

## Credits

Built on the work of:
- **[aircrack-ng/rtl8812au](https://github.com/aircrack-ng/rtl8812au)** — Monitor mode & injection foundation
- **[morrownr/8812au-20210820](https://github.com/morrownr/8812au-20210820)** — Stable DKMS packaging
- **[lwfinger/rtw88](https://github.com/lwfinger/rtw88)** — In-kernel driver (Linux 6.14+)
- **[Ac3rN/realtek-rtl88xxau-auto-installer](https://github.com/Ac3rN/realtek-rtl88xxau-auto-installer)** — Kernel 6.15–6.18 patches
- **Kali Linux packaging team** — `realtek-rtl88xxau-dkms` package

---

## License

MIT License — see [LICENSE](LICENSE) for details.