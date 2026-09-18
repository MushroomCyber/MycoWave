# MycoWave - Driver Installation Strategies

## Overview

MycoWave automatically selects the optimal driver strategy based on your kernel version, architecture, and system configuration. This document explains each strategy in detail.

---

## Strategy Selection Logic

| Kernel Version | Strategy | Driver Source | Notes |
|----------------|----------|---------------|-------|
| **≥ 6.19** | `ac3rn` | Ac3rN patched DKMS | ccflags-y/radio_idx/timer pattern (Kenji776/shchuchkin) |
| **6.15 – 6.18** | `ac3rn` | Ac3rN patched DKMS | Fixes kernel API breaks |
| **6.14** | `inkernel` | In-kernel `rtw88` | Native mac80211, no DKMS needed |
| **6.6 – 6.13** | `kali-dkms` | Kali `realtek-rtl88xxau-dkms` | Pre-built, auto-rebuilds |
| **< 6.6** | `aircrack-ng` | aircrack-ng/rtl8812au source | Latest monitor/injection fixes; see also lwfinger/rtw88 backport |

> Ranges are disjoint and checked highest-first: `ac3rn` is tested before `inkernel`
> so it stays reachable (a broad `≥ 6.14` check placed first would shadow it).

Force a specific strategy:
```bash
sudo ./mycowave-install.sh --force-method inkernel
```

---

## Strategy Details

### 1. In-Kernel `rtw88` (`inkernel`) — Kernel 6.14 (exactly)

**Best for**: Modern distributions (Kali 2026.1+, Fedora 40+, Ubuntu 24.04+, Arch)

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

**MycoWave config**: Blacklists DKMS drivers (`88XXau`, `8812au`, `8814au`)

---

### 2. Ac3rN Patched DKMS (`ac3rn`) — Kernel ≥ 6.15 (incl. 6.19+)

**Best for**: Systems on kernel 6.15+ where in-kernel not available or DKMS preferred

**Source**: https://github.com/Ac3rN/realtek-rtl88xxau-auto-installer

**Patches applied**:
- `EXTRA_CFLAGS` → `ccflags-y` (kernel 6.18+)
- `del_timer_sync()` → `timer_delete_sync()` (kernel 6.15+)
- `from_timer()` → `timer_container_of()` (kernel 6.15+)
- `cfg80211` `radio_idx` parameter support (kernel 6.16+)
- Various `-Werror` fixes

**Driver module**: `88XXau` (covers 8812au, 8821au, 8814au)

**Advantages**:
- Works on kernels 6.15–6.18 where standard DKMS fails
- Maintains monitor mode + injection support
- DKMS auto-rebuild on kernel updates

**MycoWave config**: Blacklists in-kernel `rtw_8812au`/`rtw_8821au`/`rtw_8814au`

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
- Breaks on kernel 6.15+ (API changes)
- Older than upstream aircrack-ng

**MycoWave config**: Blacklists in-kernel `rtw_8812au`/`rtw_8821au`/`rtw_8814au`

---

### 4. aircrack-ng Source (`aircrack-ng`) — Kernel < 6.6

**Best for**: Older kernels, bleeding-edge monitor/injection features

**Source**: https://github.com/aircrack-ng/rtl8812au (v5.6.4.2)

**Key contributors**:
- **astsam**: Main work + monitor/injection support
- **evilphish**: USB3, VHT, txpower control patches
- **jcard0na**: Fixed "sluggish/broken injection"
- **dpShaker**: Pre-configured SeqNum (RadioTap)
- **CGarces**: Kernel 4.15 support
- **brimstone**: Kernel 4.14 support

**Status**: **DEPRECATED** upstream — "Use mac80211 drivers over at lwfinger/rtw88".
For a maintained backport path on older kernels, see https://github.com/lwfinger/rtw88.

**Advantages**:
- Best monitor mode / frame injection support
- Latest community patches
- `rtw_tx_pwr_idx_override` module parameter (commx/dernyn fork)

**MycoWave config**: Blacklists in-kernel `rtw_8812au`/`rtw_8821au`/`rtw_8814au`

---

## Driver Conflict Resolution

MycoWave automatically handles driver conflicts by blacklisting the unused driver:

| Active Strategy | Blacklisted |
|-----------------|-------------|
| `inkernel` | `88XXau`, `8812au`, `8814au` |
| `kali-dkms`, `ac3rn`, `aircrack-ng` | `rtw_8812au`, `rtw_8821au`, `rtw_8814au` |

Blacklist files:
- `/etc/modprobe.d/blacklist-rtl88xxau.conf` (for DKMS)
- `/etc/modprobe.d/blacklist-rtw88.conf` (for in-kernel)

---

## Secure Boot Considerations

| Strategy | Secure Boot Compatible | Notes |
|----------|----------------------|-------|
| `inkernel` | ✅ Yes | Kernel modules signed by distro |
| `kali-dkms` | ✅ Yes | Kali signs DKMS modules |
| `ac3rn` | ⚠️ Manual | Requires MOK enrollment |
| `aircrack-ng` | ⚠️ Manual | Requires MOK enrollment |

Use `--secure-boot` flag to automate MOK key generation and enrollment.

---

## ARM64 / Raspberry Pi

| Strategy | Pi Support | Notes |
|----------|------------|-------|
| `inkernel` | ✅ Full | Native kernel support |
| `kali-dkms` | ✅ With `kalipi-kernel-headers` | Kali provides ARM64 packages |
| `ac3rn` | ✅ With `kalipi-kernel-headers` | Builds from source |
| `aircrack-ng` | ✅ With `kalipi-kernel-headers` | Needs `CONFIG_PLATFORM_ARM64_RPI=y` |

Use `--pi-optimizations` flag for USB power, CPU governor, and memory split tweaks.

---

## Verification

After installation, MycoWave verifies:

1. **Module loaded**: `lsmod | grep -E '88XXau|rtw_8812au'`
2. **Interface exists**: `wlan0` in `/sys/class/net/`
3. **Monitor mode works**: `airmon-ng start wlan0` → `wlan0mon`
4. **Injection capable**: `iw dev wlan0mon info | grep monitor`
5. **5GHz channels**: `iw phy phy0 channels | grep 5xxx`

---

## Manual Driver Management

```bash
# Check current driver
lsmod | grep -E '88XXau|rtw_8812au|8812au|8821au'

# Switch to in-kernel (kernel 6.14)
sudo modprobe -r 88XXau 2>/dev/null
sudo modprobe rtw_8812au

# Switch to DKMS
sudo modprobe -r rtw_8812au 2>/dev/null
sudo modprobe 88XXau

# Check DKMS status
dkms status

# Rebuild DKMS for current kernel
dkms autoinstall -k $(uname -r)
```