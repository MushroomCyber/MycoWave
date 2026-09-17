# MycoWave - Performance Optimizations

## Overview

The `--performance` flag applies a comprehensive set of optimizations for the AWUS036ACH (RTL8812AU/RTL8821AU) to maximize stability, TX power, and monitor mode reliability.

---

## Applied Optimizations

### Module Parameters (`/etc/modprobe.d/mycowave-performance.conf`)

```ini
# Force USB 2.0 mode (stability > speed for RTL8812AU chipset)
options <driver> rtw_switch_usb_mode=2

# Disable power save (prevents monitor mode drops and disconnects)
options <driver> rtw_ips_mode=0 rtw_lps_level=0

# TX power override (commx/dernyn fork, aircrack-ng v4.3.21+)
options <driver> rtw_tx_pwr_idx_override=30

# Monitor mode optimizations (aircrack-ng fork)
options <driver> rtw_monitor_disable_1m=1
options <driver> rtw_monitor_retransmit=1

# Regulatory domain: Bolivia (full 5GHz channels, high power)
options <driver> rtw_country_code=BO
```

Where `<driver>` is:
- `88XXau` for DKMS drivers (kali-dkms, ac3rn, aircrack-ng)
- `rtw88_8812au` for in-kernel driver (inkernel)

---

## Parameter Details

### `rtw_switch_usb_mode=2` — Force USB 2.0

**Values**:
- `0` = No switching (stay in current mode)
- `1` = USB 2.0 → 3.0
- `2` = USB 3.0 → 2.0 (force USB 2.0)

**Why USB 2.0?**:
- RTL8812AU is USB 2.0 device (480 Mbps theoretical)
- USB 3.0 signaling creates 2.4 GHz interference
- More stable on Pi and older USB controllers
- No throughput benefit for 802.11ac 2x2 (max ~867 Mbps PHY)

### `rtw_ips_mode=0` / `rtw_lps_level=0` — Disable Power Save

| Parameter | Value | Effect |
|-----------|-------|--------|
| `rtw_ips_mode` | 0 | Disable Idle Power Save (IPS) |
| `rtw_lps_level` | 0 | Disable Link Power Save (LPS) entirely |

**Why disable?**:
- Power save causes monitor mode to drop frames
- Link power save adds latency to channel hopping
- AWUS036ACH is externally powered (no battery concern)

### `rtw_tx_pwr_idx_override=30` — Max TX Power

**Supported by**: commx/dernyn forks, aircrack-ng v4.3.21+

**Values**: 0–30 (index into TX power table, 30 = maximum)

**Alternative** (runtime, aircrack-ng):
```bash
iw dev wlan0 set txpower fixed 3000  # 30 dBm = 3000 mBm
```

**Note**: Actual output limited by hardware and regulatory domain.

### `rtw_monitor_disable_1m=1` — Disable 1 Mbps Default

**Effect**: Prevents driver from defaulting to 1 Mbps rate in monitor mode.

**Why**: 1 Mbps is default for compatibility but kills injection performance.

### `rtw_monitor_retransmit=1` — Retransmit Injected Frames

**Effect**: Retransmits frames that fail TX in monitor mode.

**Why**: Improves injection reliability for aireplay-ng attacks.

### `rtw_country_code=BO` — Bolivia Regulatory Domain

**Why Bolivia (BO)?**:
- Most permissive regulatory domain
- All 5 GHz channels available (including DFS)
- Maximum TX power allowed (30 dBm)
- No DFS radar detection required

**Other useful domains**:
| Code | Region | Notes |
|------|--------|-------|
| `US` | FCC (USA) | DFS required on channels 52–144 |
| `DE` | ETSI (EU) | Strict, DFS required |
| `JP` | Japan | Unique channel set |
| `00` | World | Most restrictive |

**Runtime override**:
```bash
iw reg set BO
```

---

## In-Kernel rtw88 Additions

When using `inkernel` strategy, additional parameters applied:

```ini
# rtw88 (in-kernel) specific options
options rtw88_8812au rtw_switch_usb_mode=2
options rtw88_8812au rtw_lps_level=0
options rtw88_core debug_mask=0x0
```

---

## Verification

Check applied parameters:
```bash
# For DKMS driver
cat /sys/module/88XXau/parameters/rtw_switch_usb_mode
cat /sys/module/88XXau/parameters/rtw_ips_mode
cat /sys/module/88XXau/parameters/rtw_lps_level
cat /sys/module/88XXau/parameters/rtw_tx_pwr_idx_override
cat /sys/module/88XXau/parameters/rtw_country_code

# For in-kernel driver
cat /sys/module/rtw88_8812au/parameters/rtw_switch_usb_mode
cat /sys/module/rtw88_8812au/parameters/rtw_lps_level

# Check regulatory domain
iw reg get

# Check TX power
iw dev wlan0 get txpower
```

---

## Expected Improvements

| Metric | Before | After (--performance) |
|--------|--------|----------------------|
| Monitor mode stability | Drops every few min | Stable for hours |
| Injection success rate | ~60% | ~95% |
| 5GHz channel availability | Limited by regdom | All channels |
| TX power | Regdom limited | Max hardware (30 dBm) |
| USB disconnects | Occasional | Rare |

---

## Trade-offs

| Optimization | Trade-off |
|--------------|-----------|
| USB 2.0 force | Max theoretical throughput 480 Mbps (vs 5 Gbps USB3) |
| Power save disable | Higher power consumption (~500mW more) |
| Bolivia regdom | May violate local regulations |
| Max TX power | May reduce hardware lifespan, increase heat |

---

## Manual Application

```bash
# Create performance config
sudo tee /etc/modprobe.d/mycowave-performance.conf <<'EOF'
# MycoWave Performance Optimizations
options 88XXau rtw_switch_usb_mode=2
options 88XXau rtw_ips_mode=0 rtw_lps_level=0
options 88XXau rtw_tx_pwr_idx_override=30
options 88XXau rtw_monitor_disable_1m=1
options 88XXau rtw_monitor_retransmit=1
options 88XXau rtw_country_code=BO
EOF

# For in-kernel
sudo tee -a /etc/modprobe.d/mycowave-performance.conf <<'EOF'
options rtw88_8812au rtw_switch_usb_mode=2
options rtw88_8812au rtw_lps_level=0
options rtw88_core debug_mask=0x0
EOF

# Reload driver
sudo modprobe -r 88XXau rtw_8812au 2>/dev/null
sudo modprobe 88XXau  # or rtw_8812au

# Set regulatory domain
sudo iw reg set BO
```