#!/usr/bin/env bash
# =============================================================================
# MycoWave - Thermal Monitor for RTL8812AU/rtw88
# Monitors WiFi adapter temperature and applies TX power backoff
# =============================================================================

set -euo pipefail

# ─── Configuration ──────────────────────────────────────────────────────────
INTERFACE="${MYCOWAVE_INTERFACE:-wlan0}"
CHECK_INTERVAL="${MYCOWAVE_THERMAL_INTERVAL:-10}"
THERMAL_THROTTLE="${MYCOWAVE_THERMAL_THROTTLE:-80}"    # °C - Reduce TX power
THERMAL_CRITICAL="${MYCOWAVE_THERMAL_CRITICAL:-95}"    # °C - Emergency action
THERMAL_RECOVER="${MYCOWAVE_THERMAL_RECOVER:-70}"      # °C - Restore full power
LOG_TAG="mycowave-thermal"

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

# ─── State ──────────────────────────────────────────────────────────────────
THROTTLED=false
CRITICAL_ACTION=false
SENSOR_SOURCE="none"

# ARM/Raspberry Pi detection (CPU thermal zone fallback is only valid there)
is_arm() {
    case "$(uname -m)" in
        aarch64|armv7l|armv6l|arm) return 0 ;;
    esac
    [[ -f /proc/device-tree/model ]]
}

# ─── Thermal Reading ────────────────────────────────────────────────────────
read_rtw88_thermal() {
    # rtw88 debugfs thermal readings (per PHY/path)
    local debugfs_base="/sys/kernel/debug/rtw88"
    local temps=()

    if [[ -d "$debugfs_base" ]]; then
        for phy in "$debugfs_base"/phy*; do
            [[ -d "$phy" ]] || continue
            local thermal_file="$phy/thermal"
            if [[ -f "$thermal_file" ]]; then
                local temp=$(cat "$thermal_file" 2>/dev/null || echo "")
                if [[ "$temp" =~ ^[0-9]+$ ]]; then
                    temps+=("$temp")
                fi
            fi
        done
    fi

    if [[ ${#temps[@]} -gt 0 ]]; then
        # Return max temperature across all paths
        printf '%s\n' "${temps[@]}" | sort -nr | head -1
        return 0
    fi
    return 1
}

read_8812au_thermal() {
    # Morrownr/aircrack-ng driver - check if thermal param exists
    for param in /sys/module/8812au/parameters/rtw_thermal /sys/module/88XXau/parameters/rtw_thermal; do
        if [[ -f "$param" ]]; then
            local temp=$(cat "$param" 2>/dev/null || echo "")
            if [[ "$temp" =~ ^[0-9]+$ ]]; then
                echo "$temp"
                return 0
            fi
        fi
    done
    return 1
}

read_pi_cpu_thermal() {
    # Raspberry Pi CPU thermal zone
    if [[ -f /sys/class/thermal/thermal_zone0/temp ]]; then
        local temp=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
        echo $((temp / 1000))
        return 0
    fi
    return 1
}

get_max_thermal() {
    local max_temp=0
    local temp=""
    SENSOR_SOURCE="none"

    # Try rtw88 first (in-kernel)
    if temp=$(read_rtw88_thermal); then
        max_temp=$temp
        SENSOR_SOURCE="rtw88 debugfs"
    fi

    # Try 8812au (DKMS)
    if temp=$(read_8812au_thermal); then
        if [[ $temp -gt $max_temp ]]; then
            max_temp=$temp
            SENSOR_SOURCE="8812au module param"
        fi
    fi

    # CPU thermal zone fallback is only meaningful on ARM/Raspberry Pi.
    # On x86 the CPU/ACPI zone is not the WiFi adapter, so never throttle
    # WiFi TX based on it.
    if [[ $max_temp -eq 0 ]]; then
        if is_arm; then
            if temp=$(read_pi_cpu_thermal); then
                max_temp=$temp
                SENSOR_SOURCE="cpu-thermal (ARM/Pi)"
            fi
        else
            SENSOR_SOURCE="none"
        fi
    fi

    echo $max_temp
}

# ─── TX Power Control ───────────────────────────────────────────────────────
set_tx_power() {
    local power_mbm="$1"  # mBm (100 = 10 dBm, 1000 = 10 dBm, 3000 = 30 dBm)

    if command -v iw >/dev/null 2>&1; then
        if iw dev "$INTERFACE" set txpower fixed "$power_mbm" 2>/dev/null; then
            log "Set TX power to $((power_mbm / 100)) dBm ($power_mbm mBm)"
            return 0
        fi
    fi

    # Fallback to iwconfig
    if command -v iwconfig >/dev/null 2>&1; then
        local dbm=$((power_mbm / 100))
        if iwconfig "$INTERFACE" txpower "$dbm" 2>/dev/null; then
            log "Set TX power to $dbm dBm (via iwconfig)"
            return 0
        fi
    fi

    error "Failed to set TX power"
    return 1
}

get_current_tx_power() {
    if command -v iw >/dev/null 2>&1; then
        iw dev "$INTERFACE" get txpower 2>/dev/null | grep -oE '[0-9]+' | head -1
    fi
}

# ─── Thermal Actions ────────────────────────────────────────────────────────
apply_throttle() {
    log "THROTTLE: Reducing TX power to 10 dBm (1000 mBm)"
    set_tx_power 1000
    THROTTLED=true
}

apply_critical() {
    log "CRITICAL: Setting TX power to minimum (0 dBm)"
    set_tx_power 0
    CRITICAL_ACTION=true

    # Also try to disable monitor mode to reduce heat
    local mon_iface="${INTERFACE}mon"
    if [[ -e "/sys/class/net/$mon_iface" ]]; then
        log "Disabling monitor mode to reduce thermal load"
        airmon-ng stop "$mon_iface" >/dev/null 2>&1 || true
    fi
}

restore_full_power() {
    log "RECOVER: Restoring full TX power (30 dBm / 3000 mBm)"
    set_tx_power 3000
    THROTTLED=false
    CRITICAL_ACTION=false
}

# ─── Main Loop ──────────────────────────────────────────────────────────────
run_monitor() {
    log "Starting MycoWave thermal monitor for $INTERFACE"
    log "Thresholds: Throttle=${THERMAL_THROTTLE}°C, Critical=${THERMAL_CRITICAL}°C, Recover=${THERMAL_RECOVER}°C"
    log "Check interval: ${CHECK_INTERVAL}s"

    while true; do
        sleep "$CHECK_INTERVAL"

        local temp=$(get_max_thermal)

        if [[ "$SENSOR_SOURCE" == "none" || -z "$temp" || "$temp" -eq 0 ]]; then
            if is_arm; then
                warn "Could not read thermal sensor"
            else
                warn "No WiFi thermal sensor; not throttling"
            fi
            continue
        fi

        log "Current temperature: ${temp}°C (source: ${SENSOR_SOURCE})"

        # State machine
        if [[ "$CRITICAL_ACTION" == true ]]; then
            if [[ $temp -le $THERMAL_RECOVER ]]; then
                restore_full_power
            fi
        elif [[ "$THROTTLED" == true ]]; then
            if [[ $temp -ge $THERMAL_CRITICAL ]]; then
                apply_critical
            elif [[ $temp -le $THERMAL_RECOVER ]]; then
                restore_full_power
            fi
        else
            if [[ $temp -ge $THERMAL_CRITICAL ]]; then
                apply_critical
            elif [[ $temp -ge $THERMAL_THROTTLE ]]; then
                apply_throttle
            fi
        fi
    done
}

# ─── One-shot check ─────────────────────────────────────────────────────────
run_once() {
    local temp=$(get_max_thermal)

    if [[ "$SENSOR_SOURCE" == "none" || -z "$temp" || "$temp" -eq 0 ]]; then
        if is_arm; then
            error "Could not read thermal sensor"
        else
            error "No WiFi thermal sensor; not throttling"
        fi
        exit 1
    fi

    info "Temperature: ${temp}°C (source: ${SENSOR_SOURCE})"

    if [[ $temp -ge $THERMAL_CRITICAL ]]; then
        warn "CRITICAL: ${temp}°C >= ${THERMAL_CRITICAL}°C"
        exit 2
    elif [[ $temp -ge $THERMAL_THROTTLE ]]; then
        warn "THROTTLE: ${temp}°C >= ${THERMAL_THROTTLE}°C"
        exit 1
    else
        success "NORMAL: ${temp}°C < ${THERMAL_THROTTLE}°C"
        exit 0
    fi
}

# ─── Systemd Service Install ────────────────────────────────────────────────
install_service() {
    log "Installing thermal monitor systemd service..."

    cat > /etc/systemd/system/mycowave-thermal.service <<EOF
[Unit]
Description=MycoWave WiFi Thermal Monitor
Documentation=https://github.com/MushroomCyber/MycoWave
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/thermal-monitor run
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=mycowave-thermal

Environment=MYCOWAVE_INTERFACE=$INTERFACE
Environment=MYCOWAVE_THERMAL_INTERVAL=$CHECK_INTERVAL
Environment=MYCOWAVE_THERMAL_THROTTLE=$THERMAL_THROTTLE
Environment=MYCOWAVE_THERMAL_CRITICAL=$THERMAL_CRITICAL
Environment=MYCOWAVE_THERMAL_RECOVER=$THERMAL_RECOVER

# Security
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/sys/class/net /sys/kernel/debug
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable mycowave-thermal.service
    systemctl start mycowave-thermal.service

    success "Thermal monitor service installed and started"
}

# ─── CLI ─────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $0 [COMMAND]

Commands:
  run            Run thermal monitor daemon (default)
  once           Run single thermal check and exit
  install        Install as systemd service
  status         Show current thermal status
  help           Show this help

Environment Variables:
  MYCOWAVE_INTERFACE        Interface to monitor (default: wlan0)
  MYCOWAVE_THERMAL_INTERVAL Check interval in seconds (default: 10)
  MYCOWAVE_THERMAL_THROTTLE Throttle threshold °C (default: 80)
  MYCOWAVE_THERMAL_CRITICAL Critical threshold °C (default: 95)
  MYCOWAVE_THERMAL_RECOVER  Recovery threshold °C (default: 70)

Examples:
  $0                      # Run as daemon
  $0 once                 # Single check
  $0 install              # Install systemd service
  $0 status               # Show status
EOF
}

main() {
    local cmd="${1:-run}"

    case "$cmd" in
        run)
            run_monitor
            ;;
        once)
            run_once
            ;;
        install)
            install_service
            ;;
        status)
            local temp=$(get_max_thermal)
            if [[ "$SENSOR_SOURCE" != "none" && -n "$temp" && "$temp" -gt 0 ]]; then
                info "Current temperature: ${temp}°C (source: ${SENSOR_SOURCE})"
                info "Throttle threshold: ${THERMAL_THROTTLE}°C"
                info "Critical threshold: ${THERMAL_CRITICAL}°C"
                info "Recovery threshold: ${THERMAL_RECOVER}°C"

                if [[ $temp -ge $THERMAL_CRITICAL ]]; then
                    error "STATE: CRITICAL"
                elif [[ $temp -ge $THERMAL_THROTTLE ]]; then
                    warn "STATE: THROTTLED"
                else
                    success "STATE: NORMAL"
                fi
            elif is_arm; then
                error "Could not read thermal sensor"
            else
                info "No WiFi thermal sensor; not throttling"
            fi
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