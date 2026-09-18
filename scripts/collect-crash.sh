#!/usr/bin/env bash
# =============================================================================
# MycoWave - WiFi Crash Dump Collector
# Collects comprehensive diagnostic data for driver crash analysis
# =============================================================================

set -euo pipefail

# Restrict permissions on all collected diagnostic data
umask 077

# ─── Configuration ──────────────────────────────────────────────────────────
INTERFACE="${MYCOWAVE_INTERFACE:-wlan0}"
OUT_BASE_DIR="${MYCOWAVE_CRASH_DIR:-/var/log/mycowave-crashes}"
LOG_TAG="mycowave-crash"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()    { logger -t "$LOG_TAG" "$*"; echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $*"; }
info()   { logger -t "$LOG_TAG" "$*"; echo -e "${GREEN}[INFO]${NC} $*"; }
warn()   { logger -t "$LOG_TAG" "$*"; echo -e "${YELLOW}[WARN]${NC} $*"; }
error()  { logger -t "$LOG_TAG" "$*"; echo -e "${RED}[ERROR]${NC} $*"; }
success() { logger -t "$LOG_TAG" "$*"; echo -e "${GREEN}[OK]${NC} $*"; }

# ─── Collection Functions ───────────────────────────────────────────────────
create_output_dir() {
    local timestamp=$(date '+%Y%m%d-%H%M%S')
    OUT_DIR="${OUT_BASE_DIR}/${timestamp}"
    mkdir -p "$OUT_DIR"
    chmod 700 "$OUT_DIR"
    info "Output directory: $OUT_DIR"
}

collect_kernel_logs() {
    log "Collecting kernel logs..."

    # Current boot dmesg
    dmesg -T > "$OUT_DIR/dmesg-current.log" 2>/dev/null || true

    # Previous boot dmesg (if available)
    dmesg -T -b -1 > "$OUT_DIR/dmesg-previous.log" 2>/dev/null || true

    # Journalctl kernel logs (current boot)
    journalctl -b -k --no-pager > "$OUT_DIR/journal-kernel-current.log" 2>/dev/null || true

    # Journalctl kernel logs (previous boot)
    journalctl -b -1 -k --no-pager > "$OUT_DIR/journal-kernel-previous.log" 2>/dev/null || true

    # Filter for WiFi-related entries
    grep -iE "rtw88|8812au|88XXau|8821au|wlan|wifi|firmware.*crash|TX hang|recovery" \
        "$OUT_DIR/dmesg-current.log" > "$OUT_DIR/dmesg-wifi.log" 2>/dev/null || true
}

collect_debugfs() {
    log "Collecting debugfs snapshots..."

    local debugfs_base="/sys/kernel/debug/rtw88"
    if [[ -d "$debugfs_base" ]]; then
        cp -r "$debugfs_base" "$OUT_DIR/debugfs-rtw88" 2>/dev/null || true
        success "Collected rtw88 debugfs"
    else
        warn "rtw88 debugfs not available (CONFIG_RTW88_DEBUGFS=n?)"
    fi

    # Also check for 8812au debugfs if exists
    for mod in 8812au 88XXau 8821au; do
        local mod_debugfs="/sys/kernel/debug/$mod"
        if [[ -d "$mod_debugfs" ]]; then
            cp -r "$mod_debugfs" "$OUT_DIR/debugfs-$mod" 2>/dev/null || true
        fi
    done

    # Generic IEEE80211 debugfs
    if [[ -d /sys/kernel/debug/ieee80211 ]]; then
        cp -r /sys/kernel/debug/ieee80211 "$OUT_DIR/debugfs-ieee80211" 2>/dev/null || true
    fi
}

collect_module_info() {
    log "Collecting module information..."

    # All WiFi-related modules
    for mod in rtw88_core rtw88_8812au rtw88_8821au rtw88_8814au rtw88_usb 8812au 88XXau 8814au 8821au; do
        if modinfo "$mod" >/dev/null 2>&1; then
            modinfo "$mod" > "$OUT_DIR/modinfo-$mod.txt" 2>/dev/null || true

            # Module parameters
            if [[ -d /sys/module/$mod/parameters ]]; then
                for param in /sys/module/$mod/parameters/*; do
                    [[ -f "$param" ]] || continue
                    local name=$(basename "$param")
                    local value=$(cat "$param" 2>/dev/null || echo "unreadable")
                    echo "$name=$value" >> "$OUT_DIR/module-params-$mod.txt"
                done
            fi
        fi
    done

    # Loaded modules
    lsmod | grep -iE "rtw|8812|8821|8814|88xx|cfg80211|mac80211" > "$OUT_DIR/lsmod-wifi.txt" 2>/dev/null || true
}

collect_network_state() {
    log "Collecting network state..."

    # Interface info
    ip link show > "$OUT_DIR/ip-link.txt" 2>/dev/null || true
    ip addr show > "$OUT_DIR/ip-addr.txt" 2>/dev/null || true

    # Wireless info
    iw dev > "$OUT_DIR/iw-dev.txt" 2>/dev/null || true
    iw phy > "$OUT_DIR/iw-phy.txt" 2>/dev/null || true

    # Per-phy details
    for phy in /sys/class/ieee80211/phy*; do
        [[ -d "$phy" ]] || continue
        local phy_num=$(basename "$phy" | sed 's/phy//')
        iw phy "phy$phy_num" info > "$OUT_DIR/phy${phy_num}-info.txt" 2>/dev/null || true
        iw phy "phy$phy_num" channels > "$OUT_DIR/phy${phy_num}-channels.txt" 2>/dev/null || true
    done

    # Regulatory domain
    iw reg get > "$OUT_DIR/reg-domain.txt" 2>/dev/null || true

    # NetworkManager state
    nmcli device status > "$OUT_DIR/nm-device-status.txt" 2>/dev/null || true
    nmcli connection show > "$OUT_DIR/nm-connections.txt" 2>/dev/null || true

    # Routing
    ip route show > "$OUT_DIR/ip-route.txt" 2>/dev/null || true
}

collect_driver_specific() {
    log "Collecting driver-specific data..."

    # DKMS status
    dkms status > "$OUT_DIR/dkms-status.txt" 2>/dev/null || true

    # Kernel version and config
    uname -a > "$OUT_DIR/kernel-version.txt" 2>/dev/null || true

    # Kernel config for WiFi
    if [[ -f /boot/config-$(uname -r) ]]; then
        grep -iE "RTW88|RTL8812|RTL8821|CFG80211|MAC80211" /boot/config-$(uname -r) > "$OUT_DIR/kernel-config-wifi.txt" 2>/dev/null || true
    fi

    # Firmware files
    ls -la /lib/firmware/rtlwifi/ > "$OUT_DIR/firmware-rtlwifi.txt" 2>/dev/null || true
    ls -la /lib/firmware/rtw88/ > "$OUT_DIR/firmware-rtw88.txt" 2>/dev/null || true

    # Udev rules
    ls -la /etc/udev/rules.d/ > "$OUT_DIR/udev-rules.txt" 2>/dev/null || true

    # Modprobe configs (MycoWave/driver-relevant only - avoid capturing
    # unrelated system configuration)
    {
        for f in /etc/modprobe.d/mycowave-*.conf \
                 /etc/modprobe.d/*8812au*.conf \
                 /etc/modprobe.d/*88XXau*.conf \
                 /etc/modprobe.d/*rtw88*.conf; do
            [[ -f "$f" ]] || continue
            echo "### $f ###"
            cat "$f"
        done
    } > "$OUT_DIR/modprobe-configs.txt" 2>/dev/null || true

    # Systemd services
    systemctl list-units --type=service --state=active | grep -iE "mycowave|wifi|network|dkms" > "$OUT_DIR/systemd-services.txt" 2>/dev/null || true
}

collect_usb_info() {
    log "Collecting USB device info..."

    # USB tree
    lsusb -t > "$OUT_DIR/lsusb-tree.txt" 2>/dev/null || true
    lsusb -v -d 0bda: > "$OUT_DIR/lsusb-realtek.txt" 2>/dev/null || true

    # USB device details for AWUS036ACH
    for dev in /sys/bus/usb/devices/*/idVendor; do
        if [[ -f "$dev" ]] && [[ "$(cat "$dev" 2>/dev/null)" == "0bda" ]]; then
            local pid_file="${dev%idVendor}idProduct"
            if [[ -f "$pid_file" ]] && [[ "$(cat "$pid_file" 2>/dev/null)" == "a811" ]]; then
                local dev_path="${dev%idVendor}"
                local dev_num=$(basename "$dev_path")
                mkdir -p "$OUT_DIR/usb-device-$dev_num"
                cp -r "$dev_path" "$OUT_DIR/usb-device-$dev_num/" 2>/dev/null || true
                # Power state
                cat "$dev_path/power/control" > "$OUT_DIR/usb-device-$dev_num/power-control.txt" 2>/dev/null || true
                cat "$dev_path/power/autosuspend_delay_ms" > "$OUT_DIR/usb-device-$dev_num/autosuspend.txt" 2>/dev/null || true
                cat "$dev_path/power/runtime_status" > "$OUT_DIR/usb-device-$dev_num/runtime-status.txt" 2>/dev/null || true
            fi
        fi
    done
}

collect_hardware_info() {
    log "Collecting hardware info..."

    # CPU info
    lscpu > "$OUT_DIR/lscpu.txt" 2>/dev/null || true

    # Memory
    free -h > "$OUT_DIR/memory.txt" 2>/dev/null || true

    # PCI/USB devices
    lspci -nn > "$OUT_DIR/lspci.txt" 2>/dev/null || true
    lsusb > "$OUT_DIR/lsusb.txt" 2>/dev/null || true

    # DMI info (laptop/model)
    dmidecode -t system > "$OUT_DIR/dmi-system.txt" 2>/dev/null || true
    dmidecode -t baseboard > "$OUT_DIR/dmi-baseboard.txt" 2>/dev/null || true

    # Pi-specific
    if [[ -f /proc/device-tree/model ]]; then
        cat /proc/device-tree/model > "$OUT_DIR/pi-model.txt" 2>/dev/null || true
    fi
    cat /proc/cpuinfo > "$OUT_DIR/cpuinfo.txt" 2>/dev/null || true
}

create_summary() {
    log "Creating crash summary..."

    cat > "$OUT_DIR/CRASH_SUMMARY.txt" <<EOF
MycoWave Crash Dump Summary
===========================
Collected: $(date)
Hostname: $(hostname)
Kernel: $(uname -r)
Interface: $INTERFACE

=== Loaded WiFi Modules ===
$(cat "$OUT_DIR/lsmod-wifi.txt" 2>/dev/null || echo "None found")

=== Recent WiFi Kernel Messages ===
$(tail -50 "$OUT_DIR/dmesg-wifi.log" 2>/dev/null || echo "None found")

=== Interface State ===
$(ip link show "$INTERFACE" 2>/dev/null || echo "Interface not found")

=== Driver Module ===
$(for mod in rtw_8812au 88XXau 8812au rtw88_8812au; do
    if lsmod | grep -q "^$mod"; then
        echo "Active driver: $mod"
        modinfo "$mod" | grep -E "^version:|^srcversion:" 2>/dev/null
        break
    fi
done)

=== DKMS Status ===
$(cat "$OUT_DIR/dkms-status.txt" 2>/dev/null | head -20 || echo "No DKMS modules")

=== Regulatory Domain ===
$(cat "$OUT_DIR/reg-domain.txt" 2>/dev/null || echo "Unknown")

=== USB Device Power State ===
$(cat "$OUT_DIR/usb-device-*/power-control.txt" 2>/dev/null || echo "Not found")

=== Files in this dump ===
$(ls -la "$OUT_DIR")
EOF
}

compress_output() {
    log "Compressing output..."

    # Ensure collected dump files are root-only
    find "$OUT_DIR" -type f -exec chmod 600 {} + 2>/dev/null || true

    local archive="${OUT_DIR}.tar.gz"
    tar -czf "$archive" -C "$OUT_BASE_DIR" "$(basename "$OUT_DIR")" 2>/dev/null
    success "Compressed archive: $archive"
    echo "$archive"
}

# ─── CLI ─────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $0 [COMMAND]

Commands:
  collect        Collect full crash dump (default)
  collect-once   Collect and exit (for systemd timer/trigger)
  list           List previous crash dumps
  clean          Remove dumps older than 30 days
  help           Show this help

Environment Variables:
  MYCOWAVE_INTERFACE     Interface to monitor (default: wlan0)
  MYCOWAVE_CRASH_DIR     Output directory (default: /var/log/mycowave-crashes)

Examples:
  $0                      # Collect full crash dump
  $0 collect-once         # Single collection
  $0 list                 # List previous dumps
  $0 clean                # Clean old dumps
EOF
}

list_dumps() {
    log "Previous crash dumps in $OUT_BASE_DIR:"
    if [[ -d "$OUT_BASE_DIR" ]]; then
        for dump in "$OUT_BASE_DIR"/*/; do
            [[ -d "$dump" ]] || continue
            local name=$(basename "$dump")
            local summary="$dump/CRASH_SUMMARY.txt"
            if [[ -f "$summary" ]]; then
                echo "  $name:"
                head -10 "$summary" | sed 's/^/    /'
            else
                echo "  $name (no summary)"
            fi
        done
    else
        info "No crash dumps found"
    fi
}

clean_dumps() {
    log "Cleaning crash dumps older than 30 days..."
    find "$OUT_BASE_DIR" -type d -mtime +30 -exec rm -rf {} + 2>/dev/null || true
    success "Cleanup complete"
}

main() {
    local cmd="${1:-collect}"

    case "$cmd" in
        collect|collect-once)
            create_output_dir
            collect_kernel_logs
            collect_debugfs
            collect_module_info
            collect_network_state
            collect_driver_specific
            collect_usb_info
            collect_hardware_info
            create_summary
            compress_output
            success "Crash dump collected successfully"
            ;;
        list)
            list_dumps
            ;;
        clean)
            clean_dumps
            ;;
        help|--help|-h)
            usage
            ;;
        *)
            error "Unknown command: $cmd"
            usage
            exit 1
            ;;
    esac
}

main "$@"