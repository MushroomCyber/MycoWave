<div align="center">

<img src="media/mycowave-logo.png" alt="MycoWave logo" width="160">

# MycoWave

**Smart installer for the Alpha AWUS036ACH Wi-Fi adapter on Kali Linux**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE) [![Shell: Bash](https://img.shields.io/badge/Shell-Bash-green.svg)](mycowave-install.sh) [![Kali: 2024.x – 2026.1+](https://img.shields.io/badge/Kali-2024.x%20--%202026.1%2B-blue.svg)](https://www.kali.org/)

</div>

---

## Overview

MycoWave installs a working driver for the **Alpha AWUS036ACH** (RTL8812AU/RTL8821AU chipset) on Kali Linux. It detects your kernel, architecture and Secure Boot state, picks the right driver strategy automatically, and gets the adapter into monitor mode without manual `make`/`dkms` work.

**In-kernel `rtw88` and the `lwfinger` backport do managed + monitor mode well, but packet injection is not guaranteed.** For dependable `airodump-ng`/`aireplay-ng`, use an out-of-tree `88XXau` strategy (`ac3rn`, `kali-dkms`, or `aircrack-ng`).

MycoWave also handles:

- Auto-detects kernel, arch (x86_64/ARM64) and Secure Boot state, then selects a driver strategy.
- Resolves driver conflicts by blacklisting only the opposing driver family.
- Non-destructive monitor setup: a stable `awus036ach` udev symlink plus the `mycowave-monitor-mode` helper.
- Optional extras: `--performance`, `--secure-boot`, `--watchdog`, `--thermal`, `--coex`, and a crash-dump collector.
- A real-hardware test suite (`--test`) and a manifest-driven uninstall.
- Raspberry Pi / ARM64 support (`--pi-optimizations`).

---

## Requirements

- **Kali Linux** 2024.x – 2026.1+ (or Debian-based with kernel 6.6+). Kernels 6.6–7.x are supported.
- **Root** — install and uninstall commands run with `sudo`.
- **Internet connection** for packages and firmware.
- **Kernel build tree** at `/lib/modules/$(uname -r)/build` for out-of-tree strategies (`kali-dkms`, `ac3rn`, `aircrack-ng`, `lwfinger`). The `linux-headers-amd64` meta package is deliberately **not** auto-installed because it pulls a newer kernel image. On kernels ≥ 6.19, when matching headers are absent, MycoWave falls back to the in-kernel `rtw88` driver.
- **Secure Boot** — if enabled, you must enroll a MOK and reboot before a DKMS module will load (see [`docs/SECURE_BOOT.md`](docs/SECURE_BOOT.md)).

---

## Quick Start

```bash
# 1. Get the repo onto your Kali box
git clone https://github.com/MushroomCyber/MycoWave.git
cd MycoWave
chmod +x mycowave-install.sh

# 2. Plug in the AWUS036ACH, then install (auto-detects everything)
sudo ./mycowave-install.sh

# Preview what would happen first (makes no changes)
sudo ./mycowave-install.sh --dry-run

# Common non-interactive installs
sudo ./mycowave-install.sh --performance
sudo ./mycowave-install.sh --secure-boot --watchdog --thermal
sudo ./mycowave-install.sh --test
```

A bare `sudo ./mycowave-install.sh` on a terminal opens the interactive setup menu described below. Any run with flags, plus `--uninstall` and `--help`, is non-interactive.

### Interactive setup menu

Run `sudo ./mycowave-install.sh` with **no arguments on a terminal** to open the menu. It toggles performance
tuning, Secure Boot/MOK signing, Raspberry Pi optimizations, the watchdog, thermal monitoring, Bluetooth
coexistence, the crash collector (default ON), the monitor service (default OFF — it kills NetworkManager), skip
monitor automation, skip firmware, skip verification, the full test suite, dry-run, verbose, and MOK-key removal
on uninstall. It also lets you choose the regulatory domain (2-letter code, default `BO`) and the driver strategy
(auto/`inkernel`/`lwfinger`/`kali-dkms`/`ac3rn`/`aircrack-ng`).

Keys: number to toggle or choose, `p` performance preset, `d` defaults, `a` clear optional toggles, `u` (or row `18`)
to uninstall, `y` or Enter to confirm, `q` to abort, `h` for help. Enabling the full test suite selects
`--skip-verify` too, same as the `--test` flag.

The menu can also run the uninstaller: press `u` (or `18`) and type `yes` to confirm. It behaves exactly like
`--uninstall`, and honours the row 15 "Remove MOK keys on uninstall" option (same as `--uninstall --remove-mok`).

The menu only opens automatically for a bare run on a real terminal. `--menu` (`-m`) forces it, `--no-menu` skips
it, and flagged runs, `--uninstall`, `--help`, piped/CI runs and non-TTY runs behave exactly as before.
`--dry-run --menu` is allowed and stays side-effect free.

---

## Use the adapter

After install, plug in the adapter and enable monitor mode:

```bash
# Resolves the adapter (stable "awus036ach" symlink -> driver-bound netdev -> wlan0),
# runs airmon-ng, and prints the real monitor interface
sudo mycowave-monitor-mode

# Confirm the monitor interface for yourself - modern airmon-ng often keeps wlan0
iw dev

# Capture and inject using the monitor interface iw dev reports
sudo airodump-ng wlan0mon     # or wlan0 when monitor mode is in-place
sudo aireplay-ng -9 wlan0mon  # or wlan0
```

Modern `airmon-ng` enables monitor mode **in place** and does not always create `wlan0mon`. Always confirm the
name with `iw dev` (or use the value printed by `mycowave-monitor-mode`) instead of assuming a `mon` suffix.

Boot-time monitor automation is **opt-in**: `--monitor-service` installs the systemd service and NetworkManager
dispatcher, but they run `airmon-ng check kill` and will kill NetworkManager. `--skip-monitor` skips all monitor
automation (the symlink rule, helper, dispatcher and service).

### Test the install

```bash
sudo ./mycowave-install.sh --test
```

This runs the real-hardware suite — driver, monitor mode, `aireplay-ng -9` injection, 5GHz, VHT/HT, USB and
services — and prints a `managed: OK|FAILED | injection: OK|FAILED|SKIPPED` summary. It implies `--skip-verify`,
and is a no-op under `--dry-run` (which stays side-effect free).

---

## How MycoWave picks a driver

| Kernel version | Strategy | Driver |
|----------------|----------|--------|
| **≥ 6.19** (incl. 7.x) | `inkernel` | In-kernel `rtw88_8812au` (mac80211). No maintained out-of-tree rtl8812au driver supports 6.19+/7.x, and Kali rolling drops older headers, so DKMS cannot build. Managed + monitor mode; injection not guaranteed |
| **6.15 – 6.18** | `ac3rn` | Ac3rN patched source build (`install_alfa_driver.sh`; supports only 6.15/6.16/6.18) |
| **6.14** | `inkernel` | In-kernel `rtw88_8812au` (mac80211) |
| **6.6 – 6.13** | `kali-dkms` | Kali `realtek-rtl88xxau-dkms` package (frozen at 2025-03-30; hard-gated to ≤ 6.13) |
| **< 6.6** | `lwfinger` | `lwfinger/rtw88` DKMS backport (managed mode; injection not guaranteed) |

`ac3rn` and `aircrack-ng` are **not selected automatically** — they are available only via `--force-method`. Forcing `kali-dkms` on a kernel `> 6.13` is refused, because the frozen Kali package does not build on 6.15+.

Force a strategy:

```bash
sudo ./mycowave-install.sh --force-method inkernel     # managed rtw88 (recommended on 6.19+/7.x)
sudo ./mycowave-install.sh --force-method lwfinger     # managed rtw88 backport
sudo ./mycowave-install.sh --force-method aircrack-ng  # injection-focused source build
```

### Managed mode vs injection

In-kernel `rtw88` and the `lwfinger` backport are reliable in managed mode but **packet injection is unreliable** (upstream issues [#424](https://github.com/lwfinger/rtw88/issues/424)/[#428](https://github.com/lwfinger/rtw88/issues/428)/[#453](https://github.com/lwfinger/rtw88/issues/453), plus a channel-pinning regression on kernels ≥ 6.9). This is why kernels ≥ 6.19 default to `inkernel`: no out-of-tree driver can be built there.

For dependable `airodump-ng`/`aireplay-ng`, use an out-of-tree `88XXau` strategy where one is available (`ac3rn` on 6.15–6.18, `kali-dkms` on 6.6–6.13, or `--force-method aircrack-ng`).

Out-of-tree installs build the module **first** and only blacklist the in-kernel driver after a successful build. If the build fails, MycoWave removes any `/etc/modprobe.d/*.conf` containing `blacklist rtw_` and runs `update-initramfs -u`, so a working in-kernel driver is never left blacklisted.

---

## Options

```bash
sudo ./mycowave-install.sh [OPTIONS]

Options:
  --menu, -m             Show the interactive install-options menu
  --no-menu              Skip the auto-menu (use compiled-in defaults)
  --dry-run              Show what would be done without making changes
  --verbose, -v          Verbose output
  --uninstall            Remove driver and all configuration
  --force-method METHOD  Force install method: inkernel|lwfinger|kali-dkms|ac3rn|aircrack-ng
                         (kali-dkms is refused on kernels > 6.13)
  --skip-verify          Skip post-install verification
  --skip-monitor         Skip automatic monitor mode setup
  --monitor-service      Opt-in: install boot-time monitor service (kills NetworkManager)
  --reg-domain CODE      Regulatory domain for 5GHz (default: BO)
  --performance          Enable performance optimizations (USB2, disable powersave, max TX power)
  --skip-firmware        Skip firmware update check
  --secure-boot          Enable Secure Boot MOK automation
  --pi-optimizations     Enable Raspberry Pi / ARM64 optimizations
  --watchdog             Enable self-healing watchdog service
  --thermal              Enable thermal monitoring service
  --coex                 Configure Bluetooth coexistence
  --skip-crash-collector Skip crash dump collector installation
  --test                 Run comprehensive test suite after install (implies --skip-verify;
                         no-op under --dry-run)
  --remove-mok           Also delete MOK keys on --uninstall (UEFI enrollment remains)
  --help, -h             Show this help
```

`--performance` applies tuning appropriate to the selected driver family (out-of-tree `88XXau` gets USB2/power-save/TX-power options; `rtw88` gets `rtw88_core` options). See [`docs/PERFORMANCE.md`](docs/PERFORMANCE.md) for the exact settings.

---

## Uninstall

`--uninstall` is **manifest-driven**. It reads `/var/lib/mycowave/installed.files` and removes **only** the files and configs MycoWave created — the udev rule, the `mycowave-monitor-mode` helper, the NetworkManager dispatcher/service (if installed), modprobe configs, the initramfs hook, MycoWave-copied firmware, its scripts and its manifest. It also disables/stops its systemd units and unloads/DKMS-removes the modules it installed.

```bash
# Remove the driver and MycoWave configuration
sudo ./mycowave-install.sh --uninstall
# Reboot recommended
```

What it does and does not do:

- **Packages**: purges only the DKMS packages MycoWave recorded as installed. If none were recorded, `realtek-rtl88xxau-dkms` / `realtek-rtl8814au-dkms` are left untouched (remove them manually if you want).
- **`/etc/default/crda`**: never deleted while `dpkg` owns it (package-owned); removed only if MycoWave itself created it.
- **Firmware**: package-owned blobs under `/lib/firmware/rtlwifi/` and `/lib/firmware/rtw88/` are kept unless MycoWave copied them.
- **MOK keys**: kept at `/var/lib/shim-signed/mok` by default. Add `--remove-mok` to delete the key pair — note the UEFI enrollment still remains in firmware, and you must regenerate and re-enroll a MOK (then reboot) before Secure Boot will load a signed DKMS module again.
- **Logs**: the install log at `/var/log/mycowave-install.log` is left in place; crash dumps under `/var/log/mycowave-crashes/` are removed.

```bash
# Also delete the local MOK key pair (UEFI enrollment still remains)
sudo ./mycowave-install.sh --uninstall --remove-mok
```

### If you removed the driver by hand

A failed out-of-tree install can leave the working in-kernel driver blacklisted. Recover with:

```bash
sudo rm -f /etc/modprobe.d/blacklist-rtw88.conf
sudo update-initramfs -u
# or simply reinstall the in-kernel driver:
sudo ./mycowave-install.sh --force-method inkernel
```

The full install log is at `/var/log/mycowave-install.log`.

---

## What gets installed

```
├── /etc/modprobe.d/
│   ├── blacklist-rtl88xxau.conf      # Or blacklist-rtw88.conf
│   └── awus036ach-performance.conf   # (with --performance)
├── /usr/local/bin/
│   └── mycowave-monitor-mode         # Manual monitor helper (resolves + prints iface)
├── /etc/udev/rules.d/
│   └── 90-awus036ach.rules           # Stable "awus036ach" symlink (no rename)
├── /etc/NetworkManager/dispatcher.d/
│   └── 99-awus036ach-monitor         # (only with --monitor-service)
├── /etc/systemd/system/
│   └── awus036ach-monitor.service    # (only with --monitor-service)
├── /etc/initramfs-tools/scripts/init-top/
│   └── awus036ach                    # Early driver load
├── /lib/firmware/rtw88/
│   └── rtw8812a_fw.bin, rtw8821a_fw.bin  # Latest rtw88 firmware
├── /var/lib/mycowave/
│   └── installed.files               # Uninstall manifest
└── /var/log/mycowave-install.log     # Install log
```

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| **Module won't load (Secure Boot)** | Enroll the MOK (`docs/SECURE_BOOT.md`) and reboot |
| **DKMS build fails on kernel 6.15+** | Use `--force-method ac3rn` (6.15–6.18) or `--force-method lwfinger` (managed) |
| **No headers/build tree (`/lib/modules/$(uname -r)/build`)** | Out-of-tree DKMS cannot build — use `--force-method inkernel` (default on ≥ 6.19) |
| **Adapter disappears after a failed install** | Clear the stale blacklist: `sudo rm -f /etc/modprobe.d/blacklist-rtw88.conf && sudo update-initramfs -u`, then `sudo ./mycowave-install.sh --force-method inkernel` |
| **`--force-method kali-dkms` refused** | The frozen Kali package only builds ≤ 6.13; use `inkernel`/`ac3rn`/`lwfinger` instead |
| **`rtw88` injection unreliable** | Expected: use an out-of-tree `88XXau` strategy (`ac3rn`/`kali-dkms`/`aircrack-ng`) |
| **Monitor mode fails** | Run `sudo mycowave-monitor-mode` (prints the real interface); boot-time automation is opt-in via `--monitor-service` |
| **No 5GHz channels** | `sudo iw reg set BO` (or your country code) |
| **Installer waits for input** | The menu needs a terminal — pass flags or `--no-menu` for scripted runs |
| **ARM64/Pi build fails** | Ensure `kalipi-kernel-headers` installed |
| **USB disconnects** | Add `dwc_otg.fiq_fsm_enable=0` to `/boot/config.txt` (Pi) |

More issues and debug commands: [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md).

---

## Documentation

- [`docs/STRATEGIES.md`](docs/STRATEGIES.md) — driver strategy selection, kernel matrix and recovery
- [`docs/PERFORMANCE.md`](docs/PERFORMANCE.md) — `--performance` tuning details
- [`docs/SECURE_BOOT.md`](docs/SECURE_BOOT.md) — Secure Boot / MOK enrollment
- [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) — common issues and debug commands
- [`docs/ARM64.md`](docs/ARM64.md) — Raspberry Pi / ARM64 notes

---

## Development

There is no local runtime/test step — install behaviour needs a root Kali box with the adapter attached. Static checks are:

```bash
# bash -n over all shell files + shellcheck when available
./scripts/lint.sh

# Raise the shellcheck severity (default: warning)
SHELLCHECK_SEVERITY=error ./scripts/lint.sh
```

CI is a single GitHub Actions **Lint** workflow (`.github/workflows/lint.yml`) that runs `bash -n` plus `shellcheck --severity=error` on push and pull_request.

### Project structure

```
MycoWave/
├── mycowave-install.sh      # Main installer script
├── README.md                # This file
├── LICENSE                  # MIT License
├── .github/workflows/
│   └── lint.yml             # CI Lint: bash -n + shellcheck --severity=error
├── docs/
│   ├── STRATEGIES.md        # Driver strategy details
│   ├── PERFORMANCE.md       # Performance tuning guide
│   ├── SECURE_BOOT.md       # Secure Boot/MOK guide
│   ├── TROUBLESHOOTING.md   # Common issues
│   └── ARM64.md             # Raspberry Pi / ARM64 notes
└── scripts/
    ├── enroll-mok.sh        # MOK enrollment helper
    ├── wifi-watchdog.sh     # Self-healing watchdog
    ├── collect-crash.sh     # Debug crash dump collector
    └── lint.sh              # Local lint runner (bash -n + shellcheck)
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
