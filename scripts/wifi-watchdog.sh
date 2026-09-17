#!/usr/bin/env bash
# =============================================================================
# MycoWave - WiFi Driver Watchdog
# Monitors RTL8812AU/rtw88 health and auto-recovers on failure
# =============================================================================

set -euo pipefail

# ─── Configuration ──────────────────────────────────────────────────────────
INTERFACE="${MYCOWAVE_INTERFACE:-wlan0}"
CHECK_INTERVAL="${MYCOWAVE_CHECK_INTERVAL:-30}"
MAX_FAILURES="${MYCOWAVE_MAX_FAILURES:-3}"
LOG_TAG="mycowave-watchdog"

# Driver module names (tried in order)
DKMS_MODULES=("88XXau" "8812au" "8814au")
INKERNEL_MODULES=("rtw_8812au" "rtw_8821au" "rtw_8814au")
ALL_MODULES=("${DKMS_MODULES[@]}" "${INKERNEL_MODULES[@]}")

# Colors (for interactive runs)
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

# ─── Health Checks ───────────────────────────────────────────────────────────
check_interface_exists() {
    ip link show "$INTERFACE" >/dev/null 2>&1
}

check_carrier() {
    # Interface must be up and have carrier
    ip link show "$INTERFACE" | grep -q "UP" || return 1
    ethtool "$INTERFACE" 2>/dev/null | grep -q "Link detected: yes"
}

check_driver_loaded() {
    for mod in "${ALL_MODULES[@]}"; do
        if lsmod | grep -q "^$mod"; then
            LOADED_MODULE="$mod"
            return 0
        fi
    done
    return 1
}

check_tx_queue() {
    # Check debugfs for TX queue stuck (rtw88)
    local debugfs_base="/sys/kernel/debug/rtw88"
    if [[ -d "$debugfs_base" ]]; then
        for phy in "$debugfs_base"/phy*; do
            [[ -d "$phy" ]] || continue
            local txq_file="$phy/txq_status"
            if [[ -f "$txq_file" ]]; then
                if grep -qi "stuck\|hang\|timeout" "$txq_file" 2>/dev/null; then
                    return 1
                fi
            fi
        done
    fi
    return 0
}

check_firmware_crash() {
    # Check recent dmesg for firmware crash signatures
    local patterns=(
        "firmware.*crash"
        "firmware.*stop"
        "fw.*coredump"
        "TX hang"
        "tx hang"
        "rtw.*firmware.*fail"
        "rtw.*recovery"
    )

    for pattern in "${patterns[@]}"; do
        if dmesg -T --since "5 minutes ago" 2>/dev/null | grep -qi "$pattern"; then
            return 1
        fi
    done
    return 0
}

check_monitor_mode() {
    # If in monitor mode, verify mon interface exists
    local mon_iface="${INTERFACE}mon"
    if [[ -e "/sys/class/net/$mon_iface" ]]; then
        # Monitor interface exists - check it's up
        ip link show "$mon_iface" | grep -q "UP" || return 1
    fi
    return 0
}

# ─── Recovery Actions ────────────────────────────────────────────────────────
reset_usb_device() {
    log "Attempting USB device reset for $INTERFACE..."

    # Find USB device path
    local sys_path="/sys/class/net/$INTERFACE/device"
    if [[ -L "$sys_path" ]]; then
        local usb_dev=$(readlink -f "$sys_path")
        if [[ "$usb_dev" == *"/usb"* ]]; then
            # Find the USB device (not interface)
            local usb_device_path=$(dirname "$(dirname "$usb_dev")")
            local authorized_file="$usb_device_path/authorized"

            if [[ -f "$authorized_file" ]]; then
                log "Resetting USB device at $usb_device_path"
                echo 0 > "$authorized_file"
                sleep 3
                echo 1 > "$authorized_file"
                sleep 5
                return 0
            fi
        fi
    fi

    # Fallback: try to find by vendor/product
    for dev in /sys/bus/usb/devices/*/idVendor; do
        if [[ -f "$dev" ]] && [[ "$(cat "$dev" 2>/dev/null)" == "0bda" ]]; then
            local pid_file="${dev%idVendor}idProduct"
            if [[ -f "$pid_file" ]] && [[ "$(cat "$pid_file" 2>/dev/null)" == "a811" ]]; then
                local auth_file="${dev%idVendor}authorized"
                if [[ -f "$auth_file" ]]; then
                    log "Resetting USB device via vendor/product match"
                    echo 0 > "$auth_file"
                    sleep 3
                    echo 1 > "$auth_file"
                    sleep 5
                    return 0
                fi
            fi
        fi
    done

    warn "Could not find USB device to reset"
    return 1
}

reload_driver() {
    log "Reloading WiFi driver..."

    # Determine which module is loaded
    local loaded_mod=""
    for mod in "${ALL_MODULES[@]}"; do
        if lsmod | grep -q "^$mod"; then
            loaded_mod="$mod"
            break
        fi
    done

    if [[ -z "$loaded_mod" ]]; then
        warn "No driver module currently loaded"
        # Try to load DKMS first, then in-kernel
        for mod in "${DKMS_MODULES[@]}"; do
            if modprobe "$mod" 2>/dev/null; then
                loaded_mod="$mod"
                break
            fi
        done
        if [[ -z "$loaded_mod" ]]; then
            for mod in "${INKERNEL_MODULES[@]}"; do
                if modprobe "$mod" 2>/dev/null; then
                    loaded_mod="$mod"
                    break
                fi
            done
        fi
    else
        # Unload and reload
        modprobe -r "$loaded_mod" 2>/dev/null || true
        sleep 2
        modprobe "$loaded_mod" 2>/dev/null || true
    fi

    sleep 3

    if lsmod | grep -q "^$loaded_mod"; then
        success "Driver $loaded_mod reloaded"
        return 0
    else
        error "Failed to reload driver"
        return 1
    fi
}

restart_networkmanager() {
    log "Restarting NetworkManager..."
    systemctl restart NetworkManager
    sleep 3
    success "NetworkManager restarted"
}

restore_monitor_mode() {
    log "Restoring monitor mode on $INTERFACE..."

    # Kill interfering processes
    airmon-ng check kill >/dev/null 2>&1 || true

    # Start monitor mode
    if airmon-ng start "$INTERFACE" >/dev/null 2>&1; then
        local mon_iface="${INTERFACE}mon"
        if [[ -e "/sys/class/net/$mon_iface" ]]; then
            success "Monitor mode restored on $mon_iface"
            return 0
        fi
    fi

    error "Failed to restore monitor mode"
    return 1
}

full_recovery() {
    log "=== INITIATING FULL RECOVERY ==="

    local steps=(
        "reset_usb_device"
        "reload_driver"
        "restart_networkmanager"
        "restore_monitor_mode"
    )

    for step in "${steps[@]}"; do
        log "Recovery step: $step"
        if $step; then
            success "$step completed"
        else
            error "$step failed"
        fi
        sleep 2
    done

    log "=== RECOVERY COMPLETE ==="
}

# ─── Main Watchdog Loop ──────────────────────────────────────────────────────
run_watchdog() {
    log "Starting MycoWave watchdog for interface: $INTERFACE"
    log "Check interval: ${CHECK_INTERVAL}s, Max failures: $MAX_FAILURES"

    local failure_count=0
    local last_recovery=0
    local recovery_cooldown=300  # 5 minutes between full recoveries

    while true; do
        sleep "$CHECK_INTERVAL"

        local checks_failed=0
        local check_details=()

        # Run health checks
        if ! check_interface_exists; then
            ((checks_failed++))
            check_details+=("interface missing")
        fi

        if ! check_driver_loaded; then
            ((checks_failed++))
            check_details+=("driver not loaded")
        fi

        if ! check_carrier; then
            ((checks_failed++))
            check_details+=("no carrier")
        fi

        if ! check_tx_queue; then
            ((checks_failed++))
            check_details+=("TX queue stuck")
        fi

        if ! check_firmware_crash; then
            ((checks_failed++))
            check_details+=("firmware crash detected")
        fi

        if ! check_monitor_mode; then
            ((checks_failed++))
            check_details+=("monitor mode down")
        fi

        # Evaluate results
        if (( checks_failed == 0 )); then
            failure_count=0
            verbose "All checks passed"
        else
            ((failure_count++))
            warn "Health check failed ($failure_count/$MAX_FAILURES): ${check_details[*]}"

            # Check cooldown
            local now=$(date +%s)
            if (( failure_count >= MAX_FAILURES )) && (( now - last_recovery > recovery_cooldown )); then
                last_recovery=$now
                full_recovery
                failure_count=0
            fi
        fi
    done
}

# ─── One-shot check (for systemd timer or manual run) ────────────────────────
run_once() {
    log "Running single health check..."

    local checks_failed=0
    local check_details=()

    check_interface_exists || { ((checks_failed++)); check_details+=("interface missing"); }
    check_driver_loaded || { ((checks_failed++)); check_details+=("driver not loaded"); }
    check_carrier || { ((checks_failed++)); check_details+=("no carrier"); }
    check_tx_queue || { ((checks_failed++)); check_details+=("TX queue stuck"); }
    check_firmware_crash || { ((checks_failed++)); check_details+=("firmware crash"); }
    check_monitor_mode || { ((checks_failed++)); check_details+=("monitor mode down"); }

    if (( checks_failed == 0 )); then
        success "All health checks PASSED"
        exit 0
    else
        error "Health checks FAILED ($checks_failed): ${check_details[*]}"
        exit 1
    fi
}

# ─── CLI ─────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $0 [COMMAND]

Commands:
  run            Run watchdog daemon (default)
  once           Run single health check and exit
  recover        Force full recovery sequence
  status         Show current health status
  help           Show this help

Environment Variables:
  MYCOWAVE_INTERFACE       Interface to monitor (default: wlan0)
  MYCOWAVE_CHECK_INTERVAL  Check interval in seconds (default: 30)
  MYCOWAVE_MAX_FAILURES    Failures before recovery (default: 3)

Examples:
  $0                      # Run as daemon
  $0 once                 # Single check (for systemd timer)
  $0 recover              # Force recovery
  MYCOWAVE_INTERFACE=wlan1 $0 run
EOF
}

main() {
    local cmd="${1:-run}"

    case "$cmd" in
        run)
            run_watchdog
            ;;
        once)
            run_once
            ;;
        recover)
            full_recovery
            ;;
        status)
            log "Health Status for $INTERFACE:"
            check_interface_exists && info "✓ Interface exists" || error "✗ Interface missing"
            check_driver_loaded && info "✓ Driver loaded ($LOADED_MODULE)" || error "✗ Driver not loaded"
            check_carrier && info "✓ Carrier detected" || error "✗ No carrier"
            check_tx_queue && info "✓ TX queue healthy" || error "✗ TX queue stuck"
            check_firmware_crash && info "✓ No firmware crash" || error "✗ Firmware crash detected"
            check_monitor_mode && info "✓ Monitor mode OK" || error "✗ Monitor mode down"
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