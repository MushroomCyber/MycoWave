# MycoWave

> **Smart installer for Alpha AWUS036ACH Wi-Fi adapter on Kali Linux**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Shell: Bash](https://img.shields.io/badge/Shell-Bash-green.svg)](mycowave-install.sh)
[![Kali: 2024.x-2026.1+](https://img.shields.io/badge/Kali-2024.x%20-%202026.1+-blue.svg)](https://www.kali.org/)

---

## Overview

MycoWave is a version-aware, zero-intervention installer for the **Alpha AWUS036ACH** (RTL8812AU/RTL8821AU chipset) on Kali Linux. It automatically detects your kernel version, architecture, and Secure Boot state, then selects the optimal driver strategy — from in-kernel `rtw88` (Linux 6.14+) to patched DKMS builds for older kernels.

**No more manual `make`, `dkms`, or `airmon-ng` fiddling.** Plug in the adapter, run MycoWave, and you're capturing packets.

---

## Features

| Feature | Description |
|---------|-------------|
| **Auto-detection** | Kernel (6.6–6.18+), arch (x86_64/ARM64), Secure Boot, Kali version |
| **Smart strategy selection** | In-kernel `rtw88` ≥ 6.14, Kali DKMS 6.6–6.13, Ac3rN patched 6.15+, aircrack-ng source |
| **Driver conflict resolution** | Auto-blacklists competing drivers (DKMS vs in-kernel) |
| **Monitor mode automation** | udev rules + NetworkManager dispatcher + systemd service |
| **Performance optimizations** | `--performance` flag: USB2 force, powersave disable, TX power max, 5GHz unlock |
| **Firmware updates** | Auto-copies latest `rtw88xx_fw.bin` from `linux-firmware` |
| **DKMS auto-rebuild** | Initramfs hook + systemd service for kernel upgrades |
| **Post-install verification** | Module load, monitor mode, injection capability, 5GHz channels |
| **Comprehensive test suite** | `--test` flag: 20+ checks (driver, monitor, injection, 5GHz, VHT/HT, USB, services) |
| **Clean uninstall** | `--uninstall` removes everything including configs |
| **ARM64/Pi support** | Auto-installs `kalipi-kernel-headers`, USB power tweaks |
| **Secure Boot (MOK)** | `--secure-boot`: key gen, UEFI enrollment, DKMS signing |
| **Self-healing watchdog** | `--watchdog`: health checks, USB reset, driver reload, crash detection |
| **Thermal monitoring** | `--thermal`: TX power throttling at 80°C, critical at 95°C |
| **Bluetooth coexistence** | `--coex`: auto-detects internal BT, configures rtw88 coex |
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
```

After install, just **plug in the AWUS036ACH** — monitor mode starts automatically on `wlan0mon`.

---

## Installation Methods by Kernel

| Kernel Version | Strategy | Driver |
|----------------|----------|--------|
| **≥ 6.14** (Kali 2026.1+) | `inkernel` | In-kernel `rtw_8812au` (mac80211) |
| **6.15 – 6.18** | `ac3rn` | Ac3rN patched DKMS (fixes timer/cfg80211 API) |
| **6.6 – 6.13** | `kali-dkms` | Kali `realtek-rtl88xxau-dkms` package |
| **< 6.6** | `aircrack-ng` | Latest aircrack-ng/rtl8812au source |

Force a specific method:
```bash
sudo ./mycowave-install.sh --force-method ac3rn
```

---

## Options

```bash
sudo ./mycowave-install.sh [OPTIONS]

Options:
  --dry-run              Show what would be done without making changes
  --verbose, -v          Verbose output
  --uninstall            Remove driver and all configuration
  --force-method METHOD  Force install method: inkernel|kali-dkms|ac3rn|aircrack-ng
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
  --test                 Run comprehensive test suite after install
  --help, -h             Show this help
```

---

## Performance Optimizations (`--performance`)

Applies a tuned `/etc/modprobe.d/mycowave-performance.conf`:

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
│   ├── mycowave-performance.conf     # (with --performance)
├── /etc/udev/rules.d/
│   └── 90-mycowave.rules             # Consistent wlan0 naming
├── /etc/NetworkManager/dispatcher.d/
│   └── 99-mycowave-monitor           # Auto monitor on plug
├── /etc/systemd/system/
│   └── mycowave-monitor.service      # Boot-time monitor mode
├── /etc/initramfs-tools/scripts/init-top/
│   └── mycowave                       # Early driver load
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

---

## Uninstall

```bash
sudo ./mycowave-install.sh --uninstall
# Reboot recommended
```

---

## Requirements

- Kali Linux 2024.x – 2026.1+ (or Debian-based with kernel 6.6+)
- Root/sudo access
- Internet connection (for packages/firmware)
- Kernel headers (`linux-headers-$(uname -r)` or `kalipi-kernel-headers` on Pi)

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| **Module won't load (Secure Boot)** | Run `mokutil --import` with generated MOK key, enroll on reboot |
| **DKMS build fails on kernel 6.15+** | Use `--force-method ac3rn` |
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
- **[Ac3rN/realtek-rtl88xxau-auto-installer](https://github.com/Ac3rN/realtek-rtl88xxau-auto-installer)** — Kernel 6.15+ patches
- **Kali Linux packaging team** — `realtek-rtl88xxau-dkms` package

---

## License

MIT License — see [LICENSE](LICENSE) for details.