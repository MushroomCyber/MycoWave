#!/usr/bin/env bash
# =============================================================================
# MycoWave - Raspberry Pi / ARM64 Optimizations for AWUS036ACH
# Applies USB power, CPU governor, memory split, and kernel config tweaks
# =============================================================================

set -euo pipefail

# Bookworm+ moved boot firmware config to /boot/firmware
BOOT_DIR="/boot"
if [[ -d /boot/firmware ]]; then
    BOOT_DIR="/boot/firmware"
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()    { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $*"; }
info()   { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()  { echo -e "${RED}[ERROR]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }

require_root() {
    [[ $EUID -eq 0 ]] || { error "Run as root (sudo)"; exit 1; }
}

detect_pi() {
    if [[ -f /proc/device-tree/model ]]; then
        local model=$(cat /proc/device-tree/model 2>/dev/null || echo "")
        if echo "$model" | grep -qi "raspberry pi"; then
            PI_MODEL="$model"
            PI_DETECTED=true
            info "Detected: $PI_MODEL"
            return 0
        fi
    fi
    PI_DETECTED=false
    return 1
}

apply_config_txt() {
    log "Applying ${BOOT_DIR}/config.txt optimizations..."

    local config="${BOOT_DIR}/config.txt"
    local backup="${config}.mycowave.bak"

    [[ -f "$config" ]] || { warn "No $config found"; return 1; }
    cp "$config" "$backup"
    info "Backed up to $backup"

    # USB Power - Critical for AWUS036ACH (needs ~800mA)
    if ! grep -q "^max_usb_current=1" "$config"; then
        echo "max_usb_current=1" >> "$config"
        info "Set max_usb_current=1 (1.2A total USB current)"
    fi

    # Disable FIQ FSM - fixes USB dropouts with RTL8812AU
    if ! grep -q "^dwc_otg.fiq_fsm_enable=0" "$config"; then
        echo "dwc_otg.fiq_fsm_enable=0" >> "$config"
        info "Disabled FIQ FSM (dwc_otg.fiq_fsm_enable=0)"
    fi

    # Reduce NAK holdoff latency
    if ! grep -q "^dwc_otg.nak_holdoff=0" "$config"; then
        echo "dwc_otg.nak_holdoff=0" >> "$config"
        info "Set dwc_otg.nak_holdoff=0"
    fi

    # Memory split - minimal GPU for headless
    if ! grep -q "^gpu_mem=16" "$config"; then
        # Remove any existing gpu_mem line
        sed -i '/^gpu_mem=/d' "$config"
        echo "gpu_mem=16" >> "$config"
        info "Set gpu_mem=16 (minimal GPU memory)"
    fi

    # Force USB 2.0 mode for RTL8812AU (avoids 2.4GHz interference)
    # This is a kernel cmdline parameter, not config.txt
    info "USB mode forcing handled via kernel cmdline / modprobe.d"

    success "${config} updated"
}

apply_cmdline_txt() {
    log "Applying ${BOOT_DIR}/cmdline.txt kernel parameters..."

    local cmdline="${BOOT_DIR}/cmdline.txt"
    local backup="${cmdline}.mycowave.bak"

    [[ -f "$cmdline" ]] || { warn "No $cmdline found"; return 1; }
    cp "$cmdline" "$backup"
    info "Backed up to $backup"

    # Read current cmdline
    local current=$(cat "$cmdline")

    # Parameters to ensure
    local params=(
        "usbcore.autosuspend=-1"    # Disable USB autosuspend globally
        "dwc_otg.fiq_fsm_enable=0"  # Redundant but safe
    )

    local new_cmdline="$current"
    for param in "${params[@]}"; do
        if ! echo "$current" | grep -q "$param"; then
            new_cmdline="$new_cmdline $param"
            info "Added kernel parameter: $param"
        fi
    done

    echo "$new_cmdline" > "$cmdline"
    success "${cmdline} updated"
}

set_cpu_governor() {
    log "Setting CPU governor to performance..."

    # Set for current session
    for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [[ -f "$cpu" ]] && echo "performance" > "$cpu" 2>/dev/null || true
    done

    # Persist via systemd service
    cat > /etc/systemd/system/mycowave-cpu-governor.service <<'EOF'
[Unit]
Description=MycoWave CPU Performance Governor
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > $cpu; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable mycowave-cpu-governor.service
    systemctl start mycowave-cpu-governor.service

    success "CPU governor set to performance (persistent)"
}

install_kalipi_headers() {
    log "Installing kalipi-kernel-headers..."

    if dpkg -l kalipi-kernel-headers >/dev/null 2>&1; then
        info "kalipi-kernel-headers already installed"
        return 0
    fi

    apt-get update -qq
    apt-get install -y kalipi-kernel-headers

    success "kalipi-kernel-headers installed"
}

create_modprobe_config() {
    log "Creating ARM64/Pi modprobe configuration..."

    cat > /etc/modprobe.d/mycowave-pi.conf <<'EOF'
# MycoWave - Raspberry Pi / ARM64 Optimizations for RTL8812AU
# Force USB 2.0 mode (avoids 2.4GHz interference, more stable)
options 88XXau rtw_switch_usb_mode=0
options rtw88_8812au rtw_switch_usb_mode=0

# Disable deep power save (prevents disconnects on Pi USB)
options 88XXau rtw_disable_lps_deep=1

# Thermal protection
options 88XXau rtw_tx_pwr_track=1 rtw_thermal_protect=1

# Platform hint for morrownr driver
# CONFIG_PLATFORM_ARM64_RPI=y is compile-time only
EOF

    success "Created /etc/modprobe.d/mycowave-pi.conf"
}

create_udev_rules() {
    log "Creating USB power management udev rules..."

    cat > /etc/udev/rules.d/99-mycowave-usb-pm.rules <<'EOF'
# MycoWave - Disable USB autosuspend for AWUS036ACH (RTL8812AU)
# Vendor: 0bda (Realtek), Product: a811 (RTL8812AU)

ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="0bda", ATTR{idProduct}=="a811", \
    RUN+="/bin/sh -c 'echo -1 > /sys$DEVPATH/power/autosuspend_delay_ms; echo on > /sys$DEVPATH/power/control'"

# Also match by interface class (wireless)
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="0bda", ATTR{idProduct}=="a811", \
    ATTR{bInterfaceClass}=="ff", \
    RUN+="/bin/sh -c 'echo -1 > /sys$DEVPATH/power/autosuspend_delay_ms; echo on > /sys$DEVPATH/power/control'"
EOF

    udevadm control --reload-rules
    udevadm trigger --subsystem-match=usb --attr-match=idVendor=0bda --attr-match=idProduct=a811 2>/dev/null || true

    success "Created /etc/udev/rules.d/99-mycowave-usb-pm.rules"
}

show_summary() {
    log "=========================================="
    log "Pi/ARM64 Optimizations Applied:"
    log "=========================================="
    info "✓ USB current limit increased (max_usb_current=1)"
    info "✓ FIQ FSM disabled (dwc_otg.fiq_fsm_enable=0)"
    info "✓ NAK holdoff reduced (dwc_otg.nak_holdoff=0)"
    info "✓ GPU memory minimized (gpu_mem=16)"
    info "✓ USB autosuspend disabled (kernel + udev)"
    info "✓ CPU governor set to performance"
    info "✓ kalipi-kernel-headers installed"
    info "✓ Modprobe config: USB2 force, no deep LPS, thermal"
    info "✓ Udev rules: persistent power-on for AWUS036ACH"
    log "=========================================="
    warn "REBOOT REQUIRED for config.txt and cmdline.txt changes"
}

main() {
    require_root

    log "MycoWave - Raspberry Pi / ARM64 Optimizations"

    if ! detect_pi; then
        warn "Raspberry Pi not detected. Applying generic ARM64 USB tweaks only."
        create_modprobe_config
        create_udev_rules
        success "Generic ARM64 optimizations applied"
        exit 0
    fi

    apply_config_txt || warn "Boot config.txt update skipped or failed"
    apply_cmdline_txt || warn "Boot cmdline.txt update skipped or failed"
    set_cpu_governor
    install_kalipi_headers
    create_modprobe_config
    create_udev_rules

    show_summary
}

main "$@"