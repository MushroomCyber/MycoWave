# MycoWave - ARM64 / Raspberry Pi Optimizations

## Overview

The Alpha AWUS036ACH (RTL8812AU) draws significant power (~800mA peak) and is sensitive to USB signal quality. Raspberry Pi's USB controller has specific quirks that require configuration for reliable operation.

This document covers all optimizations applied by `scripts/apply-pi-optimizations.sh`.

---

## Applied Optimizations

### 1. USB Power (`/boot/config.txt`)

```ini
max_usb_current=1
```

**Effect**: Increases total USB current limit from 600mA to 1.2A (Pi 4/5 only).
**Why**: AWUS036ACH can draw 800mA+ during TX. Without this, the Pi's polyfuse trips or voltage droops cause disconnects.

### 2. FIQ FSM Disable (`/boot/config.txt` + `/boot/cmdline.txt`)

```ini
dwc_otg.fiq_fsm_enable=0
```

**Effect**: Disables the Fast Interrupt Request (FIQ) Frame State Machine in the USB driver.
**Why**: The FIQ FSM optimization conflicts with RTL8812AU's USB behavior, causing:
- Random disconnects
- "urb status -71" errors in dmesg
- Packet loss in monitor mode

### 3. NAK Holdoff Reduction (`/boot/config.txt`)

```ini
dwc_otg.nak_holdoff=0
```

**Effect**: Reduces NAK (Negative Acknowledgment) holdoff time to minimum.
**Why**: Improves USB transaction latency, reduces "endpoint halted" errors.

### 4. GPU Memory Split (`/boot/config.txt`)

```ini
gpu_mem=16
```

**Effect**: Allocates only 16MB to GPU, rest to system RAM.
**Why**: Headless operation doesn't need GPU memory; frees RAM for packet buffers.

### 5. USB Autosuspend Disable

**Global** (`/boot/cmdline.txt`):
```bash
usbcore.autosuspend=-1
```

**Per-Device** (`/etc/udev/rules.d/99-mycowave-usb-pm.rules`):
```udev
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="0bda", ATTR{idProduct}=="a811|8812|881a", \
    RUN+="/bin/sh -c 'echo -1 > /sys$DEVPATH/power/autosuspend_delay_ms; echo on > /sys$DEVPATH/power/control'"
```

The script also installs a second rule that matches the adapter's wireless interface class
(`ATTR{bInterfaceClass}=="ff"`) with the same action.

**Why**: Prevents the adapter from entering USB suspend during idle periods (e.g., between channel hops in monitor mode).

### 6. CPU Governor (`systemd service`)

```bash
# /etc/systemd/system/mycowave-cpu-governor.service
for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance > $cpu
done
```

**Why**: Prevents CPU frequency scaling latency during packet processing. Critical for sustained capture rates.

### 7. Kernel Headers

```bash
apt install kalipi-kernel-headers
```

**Why**: Standard `linux-headers-$(uname -r)` doesn't match Pi's custom kernel. `kalipi-kernel-headers` provides correct headers for DKMS builds.

### 8. Driver Module Parameters (`/etc/modprobe.d/mycowave-pi.conf`)

```ini
# Force USB 2.0 mode
options 88XXau rtw_switch_usb_mode=0
options rtw88_8812au rtw_switch_usb_mode=0

# Disable deep power save
options 88XXau rtw_disable_lps_deep=1

# Enable thermal tracking
options 88XXau rtw_tx_pwr_track=1 rtw_thermal_protect=1
```

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `rtw_switch_usb_mode` | 0 | Force USB 2.0 (avoids 2.4GHz interference from USB 3.0 signaling) |
| `rtw_disable_lps_deep` | 1 | Disable Link Power Save Deep mode (prevents disconnects) |
| `rtw_tx_pwr_track` | 1 | Enable TX power thermal tracking |
| `rtw_thermal_protect` | 1 | Enable thermal protection (reduces TX power when hot) |

---

## Verification Commands

```bash
# Check config.txt
grep -E "max_usb_current|dwc_otg|gpu_mem" /boot/config.txt

# Check cmdline.txt
cat /boot/cmdline.txt

# Check CPU governor
cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor

# Check USB power state
for dev in /sys/bus/usb/devices/*/power/control; do
    echo "$dev: $(cat $dev)"
done

# Check module parameters
cat /sys/module/88XXau/parameters/rtw_switch_usb_mode
cat /sys/module/88XXau/parameters/rtw_disable_lps_deep

# Verify kalipi headers
dpkg -l kalipi-kernel-headers
```

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|--------------|-----|
| Adapter disconnects under load | Insufficient USB power | Verify `max_usb_current=1`, use powered hub |
| "urb status -71" in dmesg | FIQ FSM conflict | Verify `dwc_otg.fiq_fsm_enable=0` |
| Monitor mode drops packets | USB autosuspend | Verify udev rule applied, check `power/control` = `on` |
| DKMS build fails | Wrong kernel headers | Install `kalipi-kernel-headers` |
| High CPU during capture | CPU governor powersave | Verify governor = `performance` |
| Adapter runs very hot | No thermal protection | Verify `rtw_thermal_protect=1` |

---

## Manual Application

If you prefer to apply manually:

```bash
# 1. Edit config.txt
sudo tee -a /boot/config.txt <<'EOF'
max_usb_current=1
dwc_otg.fiq_fsm_enable=0
dwc_otg.nak_holdoff=0
gpu_mem=16
EOF

# 2. Edit cmdline.txt
sudo sed -i 's/$/ usbcore.autosuspend=-1 dwc_otg.fiq_fsm_enable=0/' /boot/cmdline.txt

# 3. Set CPU governor
echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor

# 4. Install headers
sudo apt update && sudo apt install -y kalipi-kernel-headers

# 5. Create modprobe config
sudo tee /etc/modprobe.d/mycowave-pi.conf <<'EOF'
options 88XXau rtw_switch_usb_mode=0 rtw_disable_lps_deep=1 rtw_tx_pwr_track=1 rtw_thermal_protect=1
options rtw88_8812au rtw_switch_usb_mode=0
EOF

# 6. Create udev rule
sudo tee /etc/udev/rules.d/99-mycowave-usb-pm.rules <<'EOF'
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="0bda", ATTR{idProduct}=="a811|8812|881a", \
    RUN+="/bin/sh -c 'echo -1 > /sys$DEVPATH/power/autosuspend_delay_ms; echo on > /sys$DEVPATH/power/control'"
EOF

# 7. Reload udev
sudo udevadm control --reload-rules
sudo udevadm trigger

# 8. Reboot
sudo reboot
```

---

## References

- [RPi USB Documentation](https://www.raspberrypi.com/documentation/computers/configuration.html#configuring-usb)
- [DWC OTG Driver Parameters](https://github.com/raspberrypi/linux/blob/rpi-6.6.y/drivers/usb/dwc_otg/README)
- [morrownr 8812au ARM64_RPI](https://github.com/morrownr/8812au-20210820/blob/main/Makefile#L78)
- [RTL8812AU USB Power Issues](https://github.com/aircrack-ng/rtl8812au/issues/1025)