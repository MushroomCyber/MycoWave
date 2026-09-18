# MycoWave - Driver Installation Strategies

## Overview

MycoWave automatically selects the optimal driver strategy based on your kernel version, architecture, and system configuration. This document explains each strategy in detail.

---

## Strategy Selection Logic

| Kernel Version | Strategy | Driver Source | Notes |
|----------------|----------|---------------|-------|
| **≥ 6.19** (incl. 7.x) | `inkernel` | In-kernel `rtw88` | No maintained out-of-tree rtl8812au driver supports 6.19+/7.x and Kali rolling drops headers for older kernels, so a DKMS build is not possible. Managed + monitor mode; injection not guaranteed |
| **6.15 – 6.18** | `ac3rn` | Ac3rN patched **source build** | Entry point `install_alfa_driver.sh`; supports only 6.15/6.16/6.18 |
| **6.14** | `inkernel` | In-kernel `rtw88` | Native mac80211, no DKMS needed |
| **6.6 – 6.13** | `kali-dkms` | Kali `realtek-rtl88xxau-dkms` | Pre-built, auto-rebuilds; package is frozen at 2025-03-30 and **hard-gated to ≤ 6.13** |
| **< 6.6** | `lwfinger` | `lwfinger/rtw88` DKMS backport | **Managed mode only — injection is NOT guaranteed** |

> Ranges are disjoint and checked highest-first: `≥ 6.19` and `6.15–6.18` are tested
> before `6.14`, and `6.14` before `6.6–6.13`, so lower branches are never shadowed.

`ac3rn` and `aircrack-ng` are **not selected automatically** — they are available only
via `--force-method`. Forcing `kali-dkms` on a kernel `> 6.13` is refused with an error,
because the frozen Kali package fails to build on 6.15+. On `≥ 6.19`, `ac3rn` can only be
attempted via `--force-method` and remains unsupported.

### Out-of-tree pre-flight

All out-of-tree strategies (`kali-dkms`, `ac3rn`, `aircrack-ng`, `lwfinger`) require the
build tree for the running kernel, `/lib/modules/$(uname -r)/build`. If it is absent the
installer aborts the strategy early and points to `--force-method inkernel`. The
`linux-headers-amd64` meta package is deliberately **not** auto-installed, because it
pulls a newer kernel image.

### Managed mode vs injection

In-kernel `rtw88` (and the `lwfinger` backport) work well in **managed mode**, but
packet injection is unreliable — see upstream issues
[#424](https://github.com/lwfinger/rtw88/issues/424)/[#428](https://github.com/lwfinger/rtw88/issues/428)/[#453](https://github.com/lwfinger/rtw88/issues/453),
plus a channel-pinning regression on kernels ≥ 6.9. This is why `≥ 6.19` defaults to
in-kernel `rtw88` for managed/monitor use. For dependable `airodump-ng`/`aireplay-ng`,
use an out-of-tree `88XXau` strategy (`ac3rn`, `kali-dkms`, or `aircrack-ng`) where one
is available.

Force a specific strategy:
```bash
sudo ./mycowave-install.sh --force-method inkernel
sudo ./mycowave-install.sh --force-method lwfinger
```

---

## Strategy Details

### 1. In-Kernel `rtw88` (`inkernel`) — Kernel 6.14 and ≥ 6.19

**Best for**: Modern distributions (Kali 2026.1+, Fedora 40+, Ubuntu 24.04+, Arch)

On kernel `≥ 6.19` (including 7.x) this is the **automatic default**: no maintained
out-of-tree rtl8812au driver supports those kernels, and Kali rolling drops headers for
older kernels, so a DKMS/source build is not possible. `rtw88` supports managed and
monitor mode, but packet injection is not guaranteed.

**Driver modules**:
```
rtw88_core        # Core functionality
rtw88_88xxa       # Shared 88xxA chip code
rtw88_8812a       # RTL8812A chip-specific
rtw88_8812au      # RTL8812AU USB interface
```

**Advantages**:
- Native mac80211 compliance
- No DKMS rebuilds on kernel updates
- Full Bluetooth coexistence framework
- Beamforming (SU/MU-MIMO) support
- Thermal tracking with EWMA
- Regulatory domain via cfg80211 + EFUSE

**Limitations**:
- USB 3.0 support not fully implemented
- RX aggregation not implemented
- Requires kernel 6.14+
- **Packet injection is unreliable** (managed mode is fine) — use an out-of-tree `88XXau` strategy for `airodump-ng`/`aireplay-ng`

**MycoWave config**: Blacklists DKMS drivers (`88XXau`, `8812au`, `8814au`)

---

### 2. Ac3rN Patched Source Build (`ac3rn`) — Kernel 6.15–6.18

**Best for**: Systems on kernel 6.15–6.18 where the in-kernel driver is unavailable or an out-of-tree `88XXau` module is preferred

**Source**: https://github.com/Ac3rN/realtek-rtl88xxau-auto-installer

MycoWave runs the upstream entry point `install_alfa_driver.sh` (a **source build, not a
DKMS registration**). Upstream Ac3rN supports only kernels 6.15/6.16/6.18. On `≥ 6.19`
(incl. 7.x) there is no maintained out-of-tree path — `ac3rn` is force-only and
unsupported there, and the installer defaults to in-kernel `rtw88` instead.

**Patches applied**:
- `EXTRA_CFLAGS` → `ccflags-y` (kernel 6.18+)
- `del_timer_sync()` → `timer_delete_sync()` (kernel 6.15+)
- `from_timer()` → `timer_container_of()` (kernel 6.15+)
- `cfg80211` `radio_idx` parameter support (kernel 6.16+)
- Various `-Werror` fixes

**Driver module**: `88XXau` (covers 8812au, 8821au, 8814au)

**Advantages**:
- Works on kernels 6.15–6.18 where the standard Kali DKMS package fails
- Maintains monitor mode + injection support

**MycoWave config**: Blacklists in-kernel `rtw88_8812au`/`rtw88_8821au`/`rtw88_8814au`

---

### 3. Kali DKMS Package (`kali-dkms`) — Kernel 6.6–6.13

**Best for**: Kali Linux 2024.x – 2025.x (default kernels)

**Package**: `realtek-rtl88xxau-dkms` + `realtek-rtl8814au-dkms`

**Source**: Kali GitLab (tracked from aircrack-ng/rtl8812au)

**Version tracking**:
- Kali 2024.x: `5.6.4.2~git20240726.63cf0b4` (pinned for kernel 6.8+)
- Kali 2025.x: `5.6.4.2~git20250330.c3fb89a` (kernel 6.12+)

**Advantages**:
- Pre-built, signed packages
- Automatic DKMS rebuild on `apt upgrade`
- Kali-tested and maintained
- Secure Boot compatible (if enrolled)

**Limitations**:
- Breaks on kernel 6.15+ (API changes) — the package is frozen at 2025-03-30
- Older than upstream aircrack-ng
- Requires the running kernel's build tree (`/lib/modules/$(uname -r)/build`); the installer aborts early if it is missing
- MycoWave **hard-gates** this strategy to kernel ≤ 6.13 and refuses `--force-method kali-dkms` on 6.15+

**MycoWave config**: Blacklists in-kernel `rtw88_8812au`/`rtw88_8821au`/`rtw88_8814au`

---

### 4. lwfinger/rtw88 Backport (`lwfinger`) — Kernel < 6.6

**Best for**: Older kernels where a modern mac80211 driver is preferred over the
deprecated aircrack-ng source.

**Source**: https://github.com/lwfinger/rtw88 (DKMS)

**MycoWave `install_lwfinger` steps**:
1. Confirm the build tree `/lib/modules/$(uname -r)/build` exists (aborts early if missing)
2. `git clone https://github.com/lwfinger/rtw88`
3. CRLF-normalize `dkms.conf` (`sed -i 's/\r$//'`)
4. `dkms install "$PWD"`
5. `make install_fw` (installs the `rtw88` firmware)
6. Copy `rtw88.conf` to `/etc/modprobe.d/rtw88.conf`
7. Blacklist the opposing `88XXau`/`8812au`/`8814au` DKMS modules
8. `update-initramfs -u` and `modprobe rtw88_8812au`

**Advantages**:
- Native mac80211 stack, actively maintained backport
- No vendor `88XXau` DKMS module needed

**Limitations**:
- **Managed mode only — packet injection is NOT guaranteed** (upstream issues
  #424/#428/#453; channel-pinning bug on kernel ≥ 6.9)
- For `airodump-ng`/`aireplay-ng`, use `--force-method aircrack-ng` instead

**MycoWave config**: Blacklists `88XXau`, `8812au`, `8814au`

---

### 5. aircrack-ng Source (`aircrack-ng`) — forced only (injection workloads)

**Best for**: Reliable monitor mode / injection on any kernel; **not** an automatic
default since MycoWave's rework.

**Source**: https://github.com/aircrack-ng/rtl8812au (v5.6.4.2)

**Key contributors**:
- **astsam**: Main work + monitor/injection support
- **evilphish**: USB3, VHT, txpower control patches
- **jcard0na**: Fixed "sluggish/broken injection"
- **dpShaker**: Pre-configured SeqNum (RadioTap)
- **CGarces**: Kernel 4.15 support
- **brimstone**: Kernel 4.14 support

**Status**: **DEPRECATED** upstream — "Use mac80211 drivers over at lwfinger/rtw88".
Select it explicitly with `--force-method aircrack-ng` when injection is the priority.

**Advantages**:
- Best monitor mode / frame injection support
- Latest community patches
- `rtw_tx_pwr_idx_override` module parameter (commx/dernyn fork)

**MycoWave config**: Blacklists in-kernel `rtw88_8812au`/`rtw88_8821au`/`rtw88_8814au`

---

## Driver Conflict Resolution

MycoWave automatically handles driver conflicts by blacklisting the unused driver:

| Active Strategy | Blacklisted |
|-----------------|-------------|
| `inkernel`, `lwfinger` | `88XXau`, `8812au`, `8814au` |
| `kali-dkms`, `ac3rn`, `aircrack-ng` | `rtw88_8812au`, `rtw88_8821au`, `rtw88_8814au` |

Blacklist files:
- `/etc/modprobe.d/blacklist-rtl88xxau.conf` (for DKMS)
- `/etc/modprobe.d/blacklist-rtw88.conf` (for in-kernel)

### Build-first ordering and rollback

Out-of-tree strategies (`ac3rn`, `aircrack-ng`, and the DKMS builds) **build the module
before** blacklisting the in-kernel driver. The blacklist is only written after a
successful build, so a failed build cannot leave the working `rtw88` driver disabled.

On failure MycoWave rolls back: it removes every `/etc/modprobe.d/*.conf` containing a
`blacklist rtw_` line and runs `update-initramfs -u`. If an adapter still disappears
after a failed install, run:

```bash
sudo rm -f /etc/modprobe.d/blacklist-rtw88.conf && sudo update-initramfs -u
# or simply restore the in-kernel driver:
sudo ./mycowave-install.sh --force-method inkernel
```

---

## Secure Boot Considerations

| Strategy | Secure Boot Compatible | Notes |
|----------|----------------------|-------|
| `inkernel` | ✅ Yes | Kernel modules signed by distro |
| `lwfinger` | ⚠️ Manual | DKMS module — requires MOK enrollment |
| `kali-dkms` | ✅ Yes | Kali signs DKMS modules |
| `ac3rn` | ⚠️ Manual | Requires MOK enrollment |
| `aircrack-ng` | ⚠️ Manual | Requires MOK enrollment |

Use `--secure-boot` to automate MOK key generation/enrollment. MycoWave persists a DKMS
signing config (`/etc/dkms/framework.conf.d/mycowave-signing.conf`) so kernel-upgrade
rebuilds are auto-signed; only uncompressed `.ko` modules are signed (`.ko.zst` is skipped).

---

## ARM64 / Raspberry Pi

| Strategy | Pi Support | Notes |
|----------|------------|-------|
| `inkernel` | ✅ Full | Native kernel support |
| `lwfinger` | ✅ With `kalipi-kernel-headers` | DKMS backport builds from source |
| `kali-dkms` | ✅ With `kalipi-kernel-headers` | Kali provides ARM64 packages |
| `ac3rn` | ✅ With `kalipi-kernel-headers` | Builds from source |
| `aircrack-ng` | ✅ With `kalipi-kernel-headers` | Needs `CONFIG_PLATFORM_ARM64_RPI=y` |

Use `--pi-optimizations` flag for USB power, CPU governor, and memory split tweaks.

---

## Verification

After installation, MycoWave verifies:

1. **Module loaded**: `lsmod | grep -E '88XXau|rtw88_8812au'`
2. **Interface exists**: `wlan0` in `/sys/class/net/`
3. **Monitor mode works**: `airmon-ng start wlan0`, then read the monitor interface from `iw dev`
   (modern `airmon-ng` enables monitor mode **in place** and may keep `wlan0` instead of creating `wlan0mon`)
4. **Injection capable**: `aireplay-ng -9 <mon_iface>` (real injection test; reported as
   `managed: OK|FAILED | injection: OK|FAILED|SKIPPED` in the `--test` summary)
5. **5GHz channels**: `iw phy phy0 channels | grep 5xxx`

---

## Manual Driver Management

```bash
# Check current driver
lsmod | grep -E '88XXau|rtw88_8812au|8812au|8821au'

# Switch to in-kernel (kernel 6.14 and >= 6.19)
sudo modprobe -r 88XXau 2>/dev/null
sudo modprobe rtw88_8812au

# Switch to DKMS
sudo modprobe -r rtw88_8812au 2>/dev/null
sudo modprobe 88XXau

# Switch to lwfinger/rtw88 backport (managed mode)
sudo modprobe -r 88XXau 2>/dev/null
sudo modprobe rtw88_8812au

# Check DKMS status
dkms status

# Rebuild DKMS for current kernel
dkms autoinstall -k $(uname -r)
```

---

## Bluetooth Coexistence (`--coex`)

For the `inkernel` and `lwfinger` strategies, `--coex` auto-detects internal Bluetooth
and writes an **active** runtime toggle to `/etc/modprobe.d/mycowave-coex.conf`:

```ini
options rtw88_core rtw_btcoex_enable=1   # internal BT detected
options rtw88_core rtw_btcoex_enable=0   # no internal BT
```

For the DKMS `88XXau` strategies, coexistence is compile-time only
(`CONFIG_RTW_COEX`) — the shipped `/etc/modprobe.d/mycowave-coex.conf` is a reference
template and no runtime toggle applies.