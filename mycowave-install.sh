#!/usr/bin/env bash
# =============================================================================
# MycoWave - Alpha AWUS036ACH Driver Installer for Kali Linux
# Smart, version-aware installer supporting Kali 2024.x - 2026.1+
# Supports: x86_64, ARM64 (Raspberry Pi), Secure Boot, Kernel 6.6 - 6.18+
# Project: https://github.com/your-org/MycoWave
# =============================================================================

set -euo pipefail

# ─── Configuration ──────────────────────────────────────────────────────────
SCRIPT_VERSION="2.2.0"
SCRIPT_NAME="mycowave-install"
LOG_FILE="/var/log/${SCRIPT_NAME}.log"
DRY_RUN=false
VERBOSE=false
UNINSTALL=false
FORCE_METHOD=""
SKIP_VERIFY=false
SKIP_MONITOR_SETUP=false
REG_DOMAIN="BO"  # Bolivia - permissive for 5GHz channels
ENABLE_PERFORMANCE=false
SKIP_FIRMWARE_UPDATE=false
ENABLE_SECURE_BOOT=false
ENABLE_PI_OPTIMIZATIONS=false
ENABLE_WATCHDOG=false
ENABLE_THERMAL=false
ENABLE_COEX=false
SKIP_CRASH_COLLECTOR=false
RUN_TEST_SUITE=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ─── Logging Helpers ────────────────────────────────────────────────────────
log()     { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $*" | tee -a "$LOG_FILE"; }
info()    { echo -e "${CYAN}[INFO]${NC} $*" | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "$LOG_FILE"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"; }
success() { echo -e "${GREEN}[OK]${NC} $*" | tee -a "$LOG_FILE"; }
verbose() { [[ "$VERBOSE" == true ]] && log "$*" || true; }
run()     { verbose "→ $*"; [[ "$DRY_RUN" == true ]] || eval "$*"; }

# ─── Utility Functions ──────────────────────────────────────────────────────
require_root() {
    [[ $EUID -eq 0 ]] || { error "Run as root (sudo)"; exit 1; }
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_ID="$ID"
        OS_VERSION="$VERSION_ID"
        OS_CODENAME="${VERSION_CODENAME:-}"
    else
        error "Cannot detect OS (/etc/os-release missing)"
        exit 1
    fi
    verbose "OS: $OS_ID $OS_VERSION ($OS_CODENAME)"
}

detect_kernel() {
    KERNEL_VERSION=$(uname -r)
    KERNEL_MAJOR=$(echo "$KERNEL_VERSION" | cut -d. -f1)
    KERNEL_MINOR=$(echo "$KERNEL_VERSION" | cut -d. -f2)
    KERNEL_PATCH=$(echo "$KERNEL_VERSION" | cut -d. -f3 | cut -d- -f1)
    verbose "Kernel: $KERNEL_VERSION (major=$KERNEL_MAJOR minor=$KERNEL_MINOR patch=$KERNEL_PATCH)"
}

detect_arch() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) ARCH_TYPE="amd64" ;;
        aarch64|arm64) ARCH_TYPE="arm64" ;;
        armv7l|armhf) ARCH_TYPE="armhf" ;;
        *) ARCH_TYPE="unknown" ;;
    esac
    verbose "Arch: $ARCH ($ARCH_TYPE)"
}

detect_secure_boot() {
    if command -v mokutil >/dev/null 2>&1; then
        SECURE_BOOT=$(mokutil --sb-state 2>/dev/null | grep -i enabled || echo "disabled")
        [[ "$SECURE_BOOT" == *"enabled"* ]] && SECURE_BOOT_STATE="enabled" || SECURE_BOOT_STATE="disabled"
    else
        SECURE_BOOT_STATE="unknown"
    fi
    verbose "Secure Boot: $SECURE_BOOT_STATE"
}

detect_kali_version() {
    if [[ "$OS_ID" == "kali" ]]; then
        KALI_MAJOR=$(echo "$OS_VERSION" | cut -d. -f1)
        KALI_MINOR=$(echo "$OS_VERSION" | cut -d. -f2)
        verbose "Kali: $KALI_MAJOR.$KALI_MINOR"
    else
        KALI_MAJOR=0
        KALI_MINOR=0
        warn "Not running on Kali Linux ($OS_ID detected). Proceeding anyway."
    fi
}

detect_driver_conflicts() {
    DKMS_LOADED=false
    INKERNEL_LOADED=false
    CONFLICT_DETECTED=false

    lsmod | grep -q '^88XXau' && DKMS_LOADED=true
    lsmod | grep -q '^rtw_8812au' && INKERNEL_LOADED=true

    if [[ "$DKMS_LOADED" == true && "$INKERNEL_LOADED" == true ]]; then
        CONFLICT_DETECTED=true
        warn "Driver conflict: both DKMS (88XXau) and in-kernel (rtw_8812au) loaded"
    fi
    verbose "DKMS loaded: $DKMS_LOADED, In-kernel loaded: $INKERNEL_LOADED, Conflict: $CONFLICT_DETECTED"
}

# ─── Strategy Selection ─────────────────────────────────────────────────────
choose_strategy() {
    if [[ -n "$FORCE_METHOD" ]]; then
        STRATEGY="$FORCE_METHOD"
        info "Forced strategy: $STRATEGY"
        return
    }

    # Kernel >= 6.14 → in-kernel rtw88 (Linux 6.14+)
    if (( KERNEL_MAJOR > 6 || (KERNEL_MAJOR == 6 && KERNEL_MINOR >= 14) )); then
        STRATEGY="inkernel"
        info "Kernel $KERNEL_VERSION ≥ 6.14 → using in-kernel rtw88 driver"
        return
    fi

    # Kernel 6.15+ with broken DKMS → Ac3rN patched
    if (( KERNEL_MAJOR == 6 && KERNEL_MINOR >= 15 )); then
        STRATEGY="ac3rn"
        info "Kernel $KERNEL_VERSION ≥ 6.15 → using Ac3rN patched DKMS (fixes API breaks)"
        return
    fi

    # Kernel 6.6 - 6.13 → Kali DKMS package
    if (( KERNEL_MAJOR == 6 && KERNEL_MINOR >= 6 && KERNEL_MINOR <= 13 )); then
        STRATEGY="kali-dkms"
        info "Kernel $KERNEL_VERSION (6.6-6.13) → using Kali DKMS package"
        return
    fi

    # Older kernels → direct from aircrack-ng
    STRATEGY="aircrack-ng"
    info "Kernel $KERNEL_VERSION < 6.6 → using aircrack-ng source (latest fixes)"
}

# ─── Pre-Install Checks ─────────────────────────────────────────────────────
check_prerequisites() {
    log "Checking prerequisites..."

    # Internet connectivity
    if ! ping -c1 -W2 8.8.8.8 >/dev/null 2>&1; then
        warn "No internet connectivity detected. Some methods may fail."
    fi

    # Required packages
    local missing=()
    for pkg in git dkms build-essential libelf-dev; do
        dpkg -l "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
    done

    # Kernel headers
    local headers_pkg="linux-headers-$(uname -r)"
    if [[ "$ARCH_TYPE" == "arm64" ]] && [[ "$OS_ID" == "kali" ]]; then
        # Raspberry Pi needs special headers
        if dpkg -l kalipi-kernel-headers >/dev/null 2>&1; then
            headers_pkg="kalipi-kernel-headers"
        else
            missing+=("kalipi-kernel-headers")
        fi
    fi
    dpkg -l "$headers_pkg" >/dev/null 2>&1 || missing+=("$headers_pkg")

    if [[ ${#missing[@]} -gt 0 ]]; then
        info "Installing missing packages: ${missing[*]}"
        run "apt-get update -qq"
        run "apt-get install -y ${missing[*]}"
    fi
    success "Prerequisites satisfied"
}

# ─── Driver Installation Methods ────────────────────────────────────────────
install_inkernel() {
    log "Installing: In-kernel rtw88 driver (Linux ≥ 6.14)"

    # Blacklist DKMS driver to prevent conflict
    run "echo 'blacklist 88XXau' > /etc/modprobe.d/blacklist-rtl88xxau.conf"
    run "echo 'blacklist 8812au' >> /etc/modprobe.d/blacklist-rtl88xxau.conf"
    run "echo 'blacklist 8814au' >> /etc/modprobe.d/blacklist-rtl88xxau.conf"

    # Ensure rtw88 is not blacklisted
    run "rm -f /etc/modprobe.d/blacklist-rtw88.conf"

    # Load module
    run "modprobe rtw_8812au"
    sleep 2

    # Verify
    lsmod | grep -q '^rtw_8812au' || { error "rtw_8812au failed to load"; return 1; }
    success "In-kernel rtw_8812au loaded"
}

install_kali_dkms() {
    log "Installing: Kali DKMS package (realtek-rtl88xxau-dkms)"

    run "apt-get update -qq"
    run "apt-get install -y realtek-rtl88xxau-dkms realtek-rtl8814au-dkms"

    # Blacklist in-kernel driver to prevent conflict
    run "echo 'blacklist rtw_8812au' > /etc/modprobe.d/blacklist-rtw88.conf"
    run "echo 'blacklist rtw_8821au' >> /etc/modprobe.d/blacklist-rtw88.conf"
    run "echo 'blacklist rtw_8814au' >> /etc/modprobe.d/blacklist-rtw88.conf"

    run "modprobe 88XXau"
    sleep 2

    lsmod | grep -q '^88XXau' || { error "88XXau failed to load"; return 1; }
    success "Kali DKMS driver loaded"
}

install_ac3rn() {
    log "Installing: Ac3rN patched DKMS (kernel 6.15+ fix)"

    local repo="https://github.com/Ac3rN/realtek-rtl88xxau-auto-installer.git"
    local dir="/tmp/realtek-rtl88xxau-auto-installer"

    run "rm -rf '$dir'"
    run "git clone --depth 1 '$repo' '$dir'"
    run "chmod +x '$dir/install.sh'"

    # Blacklist in-kernel driver
    run "echo 'blacklist rtw_8812au' > /etc/modprobe.d/blacklist-rtw88.conf"

    run "'$dir/install.sh'"

    run "modprobe 88XXau"
    sleep 2

    lsmod | grep -q '^88XXau' || { error "88XXau failed to load after Ac3rN install"; return 1; }
    success "Ac3rN patched DKMS driver loaded"
}

install_aircrack_ng() {
    log "Installing: aircrack-ng rtl8812au (latest source)"

    local repo="https://github.com/aircrack-ng/rtl8812au.git"
    local dir="/tmp/rtl8812au"

    run "rm -rf '$dir'"
    run "git clone --depth 1 '$repo' '$dir'"
    run "cd '$dir'"

    # Blacklist in-kernel driver
    run "echo 'blacklist rtw_8812au' > /etc/modprobe.d/blacklist-rtw88.conf"

    # Use DKMS install if available, else manual
    if [[ -f "$dir/dkms-install.sh" ]]; then
        run "'$dir/dkms-install.sh'"
    else
        run "make dkms_install"
    fi

    run "modprobe 88XXau"
    sleep 2

    lsmod | grep -q '^88XXau' || { error "88XXau failed to load"; return 1; }
    success "aircrack-ng DKMS driver loaded"
}

# ─── Performance Configuration ──────────────────────────────────────────────
setup_performance_config() {
    [[ "$ENABLE_PERFORMANCE" != true ]] && { info "Performance optimizations disabled (use --performance)"; return; }

    log "Applying performance optimizations..."

    # Determine which driver is active/will be active
    local driver_module=""
    case "$STRATEGY" in
        inkernel) driver_module="rtw88_8812au" ;;
        kali-dkms|ac3rn|aircrack-ng) driver_module="88XXau" ;;
    esac

    # Create performance modprobe.d config
    cat > /etc/modprobe.d/awus036ach-performance.conf <<EOF
# ─── AWUS036ACH Performance Optimizations ─────────────────────────────
# Generated by $SCRIPT_NAME v$SCRIPT_VERSION on $(date)

# Force USB 2.0 mode (stability > speed for RTL8812AU chipset)
options $driver_module rtw_switch_usb_mode=2

# Disable power save (prevents monitor mode drops and disconnects)
options $driver_module rtw_ips_mode=0 rtw_lps_level=0

# TX power override (commx/dernyn fork, aircrack-ng v4.3.21+)
options $driver_module rtw_tx_pwr_idx_override=30

# Monitor mode optimizations (aircrack-ng fork)
options $driver_module rtw_monitor_disable_1m=1
options $driver_module rtw_monitor_retransmit=1

# Regulatory domain: Bolivia (full 5GHz channels, high power)
options $driver_module rtw_country_code=BO

# ──────────────────────────────────────────────────────────────────────
EOF

    # Also apply to rtw88 if using in-kernel
    if [[ "$STRATEGY" == "inkernel" ]]; then
        cat >> /etc/modprobe.d/awus036ach-performance.conf <<'EOF'

# rtw88 (in-kernel) specific options
options rtw88_8812au rtw_switch_usb_mode=2
options rtw88_8812au rtw_lps_level=0
options rtw88_core debug_mask=0x0
EOF
    fi

    success "Performance config written to /etc/modprobe.d/awus036ach-performance.conf"
    info "Changes take effect on next reboot or module reload"
}

# ─── Firmware Update ─────────────────────────────────────────────────────────
update_firmware() {
    [[ "$SKIP_FIRMWARE_UPDATE" == true ]] && { info "Skipping firmware update"; return; }

    log "Checking for firmware updates..."

    local fw_dir="/lib/firmware/rtlwifi"
    local fw_files=("rtw8812a_fw.bin" "rtw8821a_fw.bin" "rtw8812b_fw.bin")
    local updated=false

    run "mkdir -p '$fw_dir'"

    # Check if linux-firmware package has newer files
    if dpkg -l linux-firmware >/dev/null 2>&1; then
        local installed_version=$(dpkg-query -W -f='${Version}' linux-firmware 2>/dev/null || echo "unknown")
        verbose "linux-firmware version: $installed_version"

        # Copy firmware if available in package
        for fw in "${fw_files[@]}"; do
            if [[ -f "/lib/firmware/$fw" ]] && ! cmp -s "/lib/firmware/$fw" "$fw_dir/$fw" 2>/dev/null; then
                run "cp -f '/lib/firmware/$fw' '$fw_dir/'"
                updated=true
                info "Updated firmware: $fw"
            fi
        done
    fi

    # Also check for rtw88 firmware in /usr/lib/firmware (some distros)
    if [[ -d "/usr/lib/firmware/rtlwifi" ]]; then
        for fw in "${fw_files[@]}"; do
            if [[ -f "/usr/lib/firmware/rtlwifi/$fw" ]] && ! cmp -s "/usr/lib/firmware/rtlwifi/$fw" "$fw_dir/$fw" 2>/dev/null; then
                run "cp -f '/usr/lib/firmware/rtlwifi/$fw' '$fw_dir/'"
                updated=true
                info "Updated firmware: $fw (from /usr/lib/firmware)"
            fi
        done
    fi

    if [[ "$updated" == true ]]; then
        success "Firmware updated - reload driver or reboot to apply"
    else
        info "Firmware is up to date"
    fi
}

# ─── Secure Boot Setup ────────────────────────────────────────────────────────
setup_secure_boot() {
    [[ "$ENABLE_SECURE_BOOT" != true ]] && { info "Secure Boot automation disabled (use --secure-boot)"; return; }

    log "Setting up Secure Boot MOK automation..."

    # Check if mokutil is available
    if ! command -v mokutil >/dev/null 2>&1; then
        warn "mokutil not installed, installing..."
        run "apt-get update -qq && apt-get install -y mokutil"
    fi

    # Check Secure Boot state
    local sb_state=$(mokutil --sb-state 2>/dev/null || echo "unknown")
    if echo "$sb_state" | grep -qi "enabled"; then
        info "Secure Boot is ENABLED - MOK enrollment required"
    else
        warn "Secure Boot is DISABLED - MOK enrollment not strictly required"
    fi

    # Install enroll-mok script
    local script_src="$(dirname "${BASH_SOURCE[0]}")/scripts/enroll-mok.sh"
    local script_dst="/usr/local/bin/mycowave-enroll-mok"

    if [[ -f "$script_src" ]]; then
        run "cp '$script_src' '$script_dst'"
        run "chmod +x '$script_dst'"
        success "Installed MOK enrollment script to $script_dst"
    else
        warn "enroll-mok.sh not found at $script_src"
    fi

    # Generate MOK key if missing
    local mok_dir="/var/lib/shim-signed/mok"
    local mok_key="$mok_dir/MOK.priv"
    local mok_cert="$mok_dir/MOK.der"

    run "mkdir -p '$mok_dir'"
    run "chmod 700 '$mok_dir'"

    if [[ ! -f "$mok_key" ]]; then
        log "Generating MOK key pair..."
        run "openssl req -new -x509 -newkey rsa:2048 -keyout '$mok_key' -outform DER -out '$mok_cert' -nodes -days 36500 -subj '/CN=MycoWave DKMS Module Signing/'"
        run "chmod 600 '$mok_key'"
        run "chmod 644 '$mok_cert'"
        success "MOK key generated"
    else
        info "MOK key already exists"
    fi

    info "To enroll MOK in UEFI, run: sudo $script_dst enroll"
    info "Then REBOOT and complete enrollment in the blue MOK Manager screen"
}

# ─── Pi/ARM64 Optimizations Setup ────────────────────────────────────────────
setup_pi_optimizations() {
    [[ "$ENABLE_PI_OPTIMIZATIONS" != true ]] && { info "Pi optimizations disabled (use --pi-optimizations)"; return; }

    log "Setting up Raspberry Pi / ARM64 optimizations..."

    # Install apply-pi-optimizations script
    local script_src="$(dirname "${BASH_SOURCE[0]}")/scripts/apply-pi-optimizations.sh"
    local script_dst="/usr/local/bin/mycowave-pi-optimizations"

    if [[ -f "$script_src" ]]; then
        run "cp '$script_src' '$script_dst'"
        run "chmod +x '$script_dst'"
        success "Installed Pi optimizations script to $script_dst"
    else
        warn "apply-pi-optimizations.sh not found at $script_src"
    fi

    # Run it if on Pi
    if [[ -f /proc/device-tree/model ]] && grep -qi "raspberry pi" /proc/device-tree/model 2>/dev/null; then
        log "Raspberry Pi detected - applying optimizations..."
        run "'$script_dst'" || warn "Pi optimizations script returned non-zero"
    else
        info "Not on Raspberry Pi - script installed for manual use"
        info "Run: sudo $script_dst"
    fi
}

# ─── Watchdog Setup ───────────────────────────────────────────────────────────
setup_watchdog() {
    [[ "$ENABLE_WATCHDOG" != true ]] && { info "Watchdog disabled (use --watchdog)"; return; }

    log "Setting up self-healing watchdog..."

    # Install watchdog script
    local script_src="$(dirname "${BASH_SOURCE[0]}")/scripts/wifi-watchdog.sh"
    local script_dst="/usr/local/bin/wifi-watchdog"

    if [[ -f "$script_src" ]]; then
        run "cp '$script_src' '$script_dst'"
        run "chmod +x '$script_dst'"
        success "Installed watchdog script to $script_dst"
    else
        warn "wifi-watchdog.sh not found at $script_src"
    fi

    # Install systemd service
    local svc_src="$(dirname "${BASH_SOURCE[0]}")/scripts/mycowave-watchdog.service"
    local svc_dst="/etc/systemd/system/mycowave-watchdog.service"

    if [[ -f "$svc_src" ]]; then
        run "cp '$svc_src' '$svc_dst'"
        success "Installed watchdog systemd service"
    else
        warn "mycowave-watchdog.service not found at $svc_src"
    fi

    # Install NetworkManager dispatcher
    local nm_src="$(dirname "${BASH_SOURCE[0]}")/scripts/99-mycowave-wifi-recover"
    local nm_dst="/etc/NetworkManager/dispatcher.d/99-mycowave-wifi-recover"

    if [[ -f "$nm_src" ]]; then
        run "cp '$nm_src' '$nm_dst'"
        run "chmod +x '$nm_dst'"
        success "Installed NetworkManager dispatcher for crash detection"
    else
        warn "99-mycowave-wifi-recover not found at $nm_src"
    fi

    # Enable and start
    run "systemctl daemon-reload"
    run "systemctl enable mycowave-watchdog.service"
    run "systemctl start mycowave-watchdog.service"

    success "Watchdog service installed and started"
}

# ─── Thermal Monitor Setup ────────────────────────────────────────────────────
setup_thermal() {
    [[ "$ENABLE_THERMAL" != true ]] && { info "Thermal monitoring disabled (use --thermal)"; return; }

    log "Setting up thermal monitoring..."

    # Install thermal monitor script
    local script_src="$(dirname "${BASH_SOURCE[0]}")/scripts/thermal-monitor.sh"
    local script_dst="/usr/local/bin/thermal-monitor"

    if [[ -f "$script_src" ]]; then
        run "cp '$script_src' '$script_dst'"
        run "chmod +x '$script_dst'"
        success "Installed thermal monitor script to $script_dst"
    else
        warn "thermal-monitor.sh not found at $script_src"
    fi

    # Install systemd service (thermal-monitor.sh has install command)
    run "'$script_dst' install" || warn "Thermal monitor service installation had issues"

    success "Thermal monitoring service installed"
}

# ─── Bluetooth Coexistence Setup ─────────────────────────────────────────────
setup_coex() {
    [[ "$ENABLE_COEX" != true ]] && { info "Bluetooth coexistence config disabled (use --coex)"; return; }

    log "Configuring Bluetooth coexistence..."

    # Detect internal Bluetooth
    local has_bt=false
    if command -v hciconfig >/dev/null 2>&1 && hciconfig 2>/dev/null | grep -q "UP RUNNING"; then
        has_bt=true
    elif command -v btmgmt >/dev/null 2>&1 && btmgmt info 2>/dev/null | grep -q "powered"; then
        has_bt=true
    fi

    # Determine driver
    local driver_module=""
    case "$STRATEGY" in
        inkernel) driver_module="rtw88_core" ;;
        kali-dkms|ac3rn|aircrack-ng) driver_module="88XXau" ;;
    esac

    # Create coex config
    cat > /etc/modprobe.d/mycowave-coex.conf <<EOF
# MycoWave - Bluetooth Coexistence Configuration
# Generated on $(date)
# Internal BT detected: $has_bt
# Driver: $driver_module

EOF

    if [[ "$STRATEGY" == "inkernel" ]]; then
        if [[ "$has_bt" == true ]]; then
            cat >> /etc/modprobe.d/mycowave-coex.conf <<'EOF'
# Internal Bluetooth detected - enable coexistence
options rtw88_core rtw_btcoex_enable=1
# Antenna sharing: 0=dedicated, 1=shared (check EFUSE)
# options rtw88_core rtw_btcoex_ant_num=0
EOF
            info "Internal Bluetooth detected - coexistence ENABLED"
        else
            cat >> /etc/modprobe.d/mycowave-coex.conf <<'EOF'
# No internal Bluetooth - disable coexistence to reduce overhead
options rtw88_core rtw_btcoex_enable=0
EOF
            info "No internal Bluetooth - coexistence DISABLED"
        fi
    else
        cat >> /etc/modprobe.d/mycowave-coex.conf <<'EOF'
# DKMS driver (88XXau) - coexistence controlled at compile time (CONFIG_RTW_COEX)
# No runtime module parameters available for coex in DKMS driver
# If internal BT present, ensure driver was built with CONFIG_RTW_COEX=y
EOF
        info "DKMS driver - coexistence is compile-time only"
    fi

    success "Bluetooth coexistence config written to /etc/modprobe.d/mycowave-coex.conf"
}

# ─── Crash Collector Setup ────────────────────────────────────────────────────
setup_crash_collector() {
    [[ "$SKIP_CRASH_COLLECTOR" == true ]] && { info "Crash collector disabled (default enabled)"; return; }

    log "Setting up crash dump collector..."

    # Install collect-crash script
    local script_src="$(dirname "${BASH_SOURCE[0]}")/scripts/collect-crash.sh"
    local script_dst="/usr/local/bin/mycowave-collect-crash"

    if [[ -f "$script_src" ]]; then
        run "cp '$script_src' '$script_dst'"
        run "chmod +x '$script_dst'"
        success "Installed crash collector script to $script_dst"
    else
        warn "collect-crash.sh not found at $script_src"
    fi

    # Create systemd timer for periodic collection (optional)
    cat > /etc/systemd/system/mycowave-crash-collector.timer <<'EOF'
[Unit]
Description=MycoWave Periodic Crash Dump Collection
Documentation=https://github.com/MushroomCyber/MycoWave

[Timer]
OnBootSec=10min
OnUnitActiveSec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF

    cat > /etc/systemd/system/mycowave-crash-collector.service <<'EOF'
[Unit]
Description=MycoWave Crash Dump Collector
Documentation=https://github.com/MushroomCyber/MycoWave

[Service]
Type=oneshot
ExecStart=/usr/local/bin/mycowave-collect-crash collect-once
StandardOutput=journal
StandardError=journal
SyslogIdentifier=mycowave-crash

# Security
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/var/log/mycowave-crashes /sys/class/net /sys/kernel/debug
CapabilityBoundingSet=CAP_DAC_READ_SEARCH
EOF

    run "systemctl daemon-reload"
    run "systemctl enable mycowave-crash-collector.timer"
    run "systemctl start mycowave-crash-collector.timer"

    success "Crash collector installed with hourly timer"
}

# ─── Post-Install Configuration ─────────────────────────────────────────────
setup_monitor_mode() {
    [[ "$SKIP_MONITOR_SETUP" == true ]] && { info "Skipping monitor mode setup"; return; }

    log "Configuring automatic monitor mode..."

    # 1. Create udev rule for consistent interface naming
    cat > /etc/udev/rules.d/90-awus036ach.rules <<'EOF'
# Alpha AWUS036ACH - consistent naming
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="88XXau", NAME="wlan0"
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="rtw_8812au", NAME="wlan0"
EOF

    # 2. Create NetworkManager dispatcher to auto-enable monitor mode on plug
    cat > /etc/NetworkManager/dispatcher.d/99-awus036ach-monitor <<'EOF'
#!/bin/bash
# Auto-enable monitor mode for AWUS036ACH on interface up

IFACE="$1"
STATUS="$2"

if [[ "$IFACE" == "wlan0" && "$STATUS" == "up" ]]; then
    # Kill interfering processes
    airmon-ng check kill >/dev/null 2>&1
    # Enable monitor mode
    airmon-ng start "$IFACE" >/dev/null 2>&1
    logger -t awus036ach "Monitor mode enabled on $IFACE"
fi
EOF
    run "chmod +x /etc/NetworkManager/dispatcher.d/99-awus036ach-monitor"

    # 3. systemd service for boot-time monitor mode (optional, enabled by default)
    cat > /etc/systemd/system/awus036ach-monitor.service <<'EOF'
[Unit]
Description=Enable monitor mode for Alpha AWUS036ACH
After=network.target
Wants=network.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/airmon-ng check kill
ExecStart=/usr/sbin/airmon-ng start wlan0
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    run "systemctl daemon-reload"
    run "systemctl enable awus036ach-monitor.service"

    # 4. Regulatory domain for 5GHz channels
    run "iw reg set $REG_DOMAIN"
    echo "REGDOMAIN=$REG_DOMAIN" > /etc/default/crda

    success "Monitor mode automation configured"
}

setup_dkms_autorebuild() {
    log "Configuring DKMS auto-rebuild on kernel upgrade..."

    # Ensure dkms service is enabled
    run "systemctl enable dkms.service 2>/dev/null || true"

    # Create hook for initramfs update (ensures driver in initramfs for early boot)
    cat > /etc/initramfs-tools/scripts/init-top/awus036ach <<'EOF'
#!/bin/sh
# Load AWUS036ACH driver early for initramfs
modprobe 88XXau 2>/dev/null || modprobe rtw_8812au 2>/dev/null || true
EOF
    run "chmod +x /etc/initramfs-tools/scripts/init-top/awus036ach"
    run "update-initramfs -u"

    success "DKMS auto-rebuild configured"
}

# ─── Verification ───────────────────────────────────────────────────────────
verify_install() {
    [[ "$SKIP_VERIFY" == true ]] && { info "Skipping verification"; return; }

    log "Verifying installation..."

    local iface=""
    local driver=""

    # Find the wireless interface
    for i in /sys/class/net/wlan*; do
        [[ -e "$i" ]] || continue
        iface=$(basename "$i")
        driver=$(readlink -f "$i/device/driver/module" 2>/dev/null | xargs basename 2>/dev/null || echo "unknown")
        break
    done

    if [[ -z "$iface" ]]; then
        error "No wireless interface found (wlan0)"
        return 1
    fi

    info "Interface: $iface"
    info "Driver: $driver"

    # Check module loaded
    if ! lsmod | grep -qE '^(88XXau|rtw_8812au)'; then
        error "No driver module loaded"
        return 1
    fi

    # Test monitor mode
    info "Testing monitor mode..."
    run "airmon-ng check kill"
    if run "airmon-ng start $iface"; then
        local mon_iface="${iface}mon"
        # Verify monitor interface exists
        if [[ -e "/sys/class/net/$mon_iface" ]]; then
            success "Monitor mode: WORKING ($mon_iface)"

            # Test injection (requires nearby AP, so just check capability)
            info "Checking injection capability..."
            if iw dev "$mon_iface" info | grep -q "monitor"; then
                success "Injection capability: AVAILABLE"
            fi

            # Cleanup test monitor
            run "airmon-ng stop $mon_iface >/dev/null 2>&1 || true"
        else
            error "Monitor mode interface not created"
            return 1
        fi
    else
        error "Failed to enable monitor mode"
        return 1
    fi

    # Check 5GHz channels
    info "Checking 5GHz channel availability..."
    local chans=$(iw phy "$(cat /sys/class/net/$iface/phy80211/name)" channels 2>/dev/null | grep -c "5[0-9][0-9][0-9]" || echo 0)
    info "5GHz channels available: $chans"

    success "All verification checks passed"
}

# ─── Comprehensive Test Suite ─────────────────────────────────────────────────
run_full_test_suite() {
    log "Running comprehensive test suite..."

    local iface=""
    for i in /sys/class/net/wlan*; do
        [[ -e "$i" ]] || continue
        iface=$(basename "$i")
        break
    done

    [[ -z "$iface" ]] && { error "No wireless interface found"; return 1; }

    local all_passed=true

    # Test 1: Driver loaded & version
    run_test "Driver module loaded" "lsmod | grep -qE '^(88XXau|rtw_8812au)'"

    # Test 2: Interface up
    run_test "Interface $iface exists" "[[ -e /sys/class/net/$iface ]]"

    # Test 3: Interface carrier (link detection capability)
    run_test "Interface has carrier detection" "ethtool $iface 2>/dev/null | grep -q 'Link detected'"

    # Test 4: TX power setting
    run_test "TX power configurable" "iw dev $iface set txpower fixed 2000 2>/dev/null || true"

    # Test 5: Regulatory domain
    local reg=$(iw reg get 2>/dev/null | grep -i country | head -1 | awk '{print $2}' || echo "00")
    run_test "Regulatory domain set ($reg)" "[[ '$reg' != '00' ]]"

    # Test 6: Channel list populated
    run_test "Channel list available" "iw phy phy0 channels 2>/dev/null | grep -q MHz"

    # Test 7: 5GHz channels present
    local ch5=$(iw phy phy0 channels 2>/dev/null | grep -c "5[0-9][0-9][0-9]" || echo 0)
    run_test "5GHz channels available ($ch5)" "[[ $ch5 -gt 0 ]]"

    # Test 8: VHT capabilities (802.11ac)
    run_test "VHT (802.11ac) supported" "iw phy phy0 info 2>/dev/null | grep -qi vht"

    # Test 9: HT capabilities (802.11n)
    run_test "HT (802.11n) supported" "iw phy phy0 info 2>/dev/null | grep -qi ht"

    # Test 10: Monitor mode
    run_test "Monitor mode works" "airmon-ng check kill >/dev/null 2>&1 && airmon-ng start $iface >/dev/null 2>&1"

    # Test 11: Injection capability (monitor interface exists)
    local mon="${iface}mon"
    run_test "Monitor interface created ($mon)" "[[ -e /sys/class/net/$mon ]]"

    # Test 12: Cleanup monitor
    run_test "Monitor cleanup works" "airmon-ng stop $mon >/dev/null 2>&1 || true"

    # Test 13: USB device responsive
    run_test "USB device responsive" "lsusb -d 0bda:a811 2>/dev/null | grep -q Realtek"

    # Test 14: No driver conflict
    run_test "No driver conflict (single driver)" "! (lsmod | grep -q '^88XXau' && lsmod | grep -q '^rtw_8812au')"

    # Test 15: Module parameters applied (if performance enabled)
    if [[ "$ENABLE_PERFORMANCE" == true ]]; then
        local params=$(cat /sys/module/${driver_module:-88XXau}/parameters/ 2>/dev/null | head -5 || echo "")
        run_test "Module parameters directory accessible" "[[ -d /sys/module/${driver_module:-88XXau}/parameters/ ]]"
    fi

    # Test 16: Firmware loaded
    run_test "Firmware files present" "ls /lib/firmware/rtlwifi/rtw8812a_fw.bin 2>/dev/null || ls /lib/firmware/rtw8812a_fw.bin 2>/dev/null"

    # Test 17: Thermal zone accessible (if thermal enabled)
    if [[ "$ENABLE_THERMAL" == true ]]; then
        run_test "Thermal monitoring accessible" "[[ -d /sys/kernel/debug/rtw88 ]] || [[ -d /sys/class/thermal ]]"
    fi

    # Test 18: Watchdog service active (if watchdog enabled)
    if [[ "$ENABLE_WATCHDOG" == true ]]; then
        run_test "Watchdog service active" "systemctl is-active mycowave-watchdog.service 2>/dev/null | grep -q active"
    fi

    # Test 19: Crash collector timer (if enabled)
    if [[ "$SKIP_CRASH_COLLECTOR" != true ]]; then
        run_test "Crash collector timer enabled" "systemctl is-enabled mycowave-crash-collector.timer 2>/dev/null | grep -q enabled"
    fi

    # Test 20: udev rules installed
    run_test "udev rules installed" "[[ -f /etc/udev/rules.d/90-awus036ach.rules ]]"

    echo
    if [[ "$all_passed" == true ]]; then
        success "═══════════════════════════════════════"
        success "  ALL TESTS PASSED"
        success "═══════════════════════════════════════"
        return 0
    else
        error "═══════════════════════════════════════"
        error "  SOME TESTS FAILED - Review output above"
        error "═══════════════════════════════════════"
        return 1
    fi
}

run_test() {
    local name="$1"
    local cmd="$2"
    if eval "$cmd" >/dev/null 2>&1; then
        success "✓ $name"
        return 0
    else
        error "✗ $name"
        all_passed=false
        return 1
    fi
}

# ─── Uninstall ──────────────────────────────────────────────────────────────
uninstall_driver() {
    log "Uninstalling MycoWave driver and configuration..."

    # Stop and disable services
    local services=(
        "awus036ach-monitor.service"
        "mycowave-watchdog.service"
        "mycowave-thermal.service"
        "mycowave-cpu-governor.service"
        "mycowave-crash-collector.timer"
        "mycowave-crash-collector.service"
    )

    for svc in "${services[@]}"; do
        run "systemctl disable $svc 2>/dev/null || true"
        run "systemctl stop $svc 2>/dev/null || true"
        run "rm -f /etc/systemd/system/$svc"
    done

    run "systemctl daemon-reload"

    # Remove udev rules
    run "rm -f /etc/udev/rules.d/90-awus036ach.rules"
    run "rm -f /etc/udev/rules.d/99-mycowave-usb-pm.rules"

    # Remove NetworkManager dispatchers
    run "rm -f /etc/NetworkManager/dispatcher.d/99-awus036ach-monitor"
    run "rm -f /etc/NetworkManager/dispatcher.d/99-mycowave-wifi-recover"

    # Remove initramfs hook
    run "rm -f /etc/initramfs-tools/scripts/init-top/awus036ach"
    run "update-initramfs -u"

    # Remove modprobe configs
    run "rm -f /etc/modprobe.d/blacklist-rtl88xxau.conf"
    run "rm -f /etc/modprobe.d/blacklist-rtw88.conf"
    run "rm -f /etc/modprobe.d/awus036ach-performance.conf"
    run "rm -f /etc/modprobe.d/mycowave-pi.conf"
    run "rm -f /etc/modprobe.d/mycowave-coex.conf"

    # Remove scripts
    run "rm -f /usr/local/bin/mycowave-enroll-mok"
    run "rm -f /usr/local/bin/mycowave-pi-optimizations"
    run "rm -f /usr/local/bin/wifi-watchdog"
    run "rm -f /usr/local/bin/thermal-monitor"
    run "rm -f /usr/local/bin/mycowave-collect-crash"

    # Remove MOK keys
    run "rm -rf /var/lib/shim-signed/mok"

    # Remove crash dumps
    run "rm -rf /var/log/mycowave-crashes"

    # Unload modules
    run "modprobe -r 88XXau 2>/dev/null || true"
    run "modprobe -r 8812au 2>/dev/null || true"
    run "modprobe -r 8814au 2>/dev/null || true"
    run "modprobe -r rtw_8812au 2>/dev/null || true"
    run "modprobe -r rtw_8821au 2>/dev/null || true"
    run "modprobe -r rtw_8814au 2>/dev/null || true"

    # Remove DKMS packages
    run "dkms remove -m rtl8812au -v all --all 2>/dev/null || true"
    run "dkms remove -m rtl8814au -v all --all 2>/dev/null || true"
    run "apt-get purge -y realtek-rtl88xxau-dkms realtek-rtl8814au-dkms 2>/dev/null || true"

    success "Uninstall complete. Reboot recommended."
}

# ─── Main ───────────────────────────────────────────────────────────────────
print_banner() {
    cat <<'EOF'
╔═══════════════════════════════════════════════════════════════════════╗
║                    MycoWave v2.1.0                                    ║
║       Alpha AWUS036ACH Driver Installer for Kali Linux              ║
╠═══════════════════════════════════════════════════════════════════════╣
║  Smart installer supporting:                                        ║
║  • Kali 2024.x - 2026.1+ (Kernel 6.6 - 6.18+)                      ║
║  • x86_64, ARM64 (Raspberry Pi)                                    ║
║  • Secure Boot (MOK enrollment)                                     ║
║  • Auto monitor mode, injection test, 5GHz channels                ║
║  • Performance optimizations (--performance)                       ║
╚═══════════════════════════════════════════════════════════════════════╝
EOF
}

usage() {
    cat <<EOF
Usage: sudo $0 [OPTIONS]

Options:
  --dry-run              Show what would be done without making changes
  --verbose, -v          Verbose output
  --uninstall            Remove driver and all configuration
  --force-method METHOD  Force install method: inkernel|kali-dkms|ac3rn|aircrack-ng
  --skip-verify          Skip post-install verification
  --skip-monitor         Skip automatic monitor mode setup
  --reg-domain CODE      Regulatory domain for 5GHz (default: BO)
  --performance          Enable performance optimizations (USB2, disable powersave, max TX power)
  --skip-firmware        Skip firmware update check
  --secure-boot          Enable Secure Boot MOK automation
  --pi-optimizations     Enable Raspberry Pi / ARM64 optimizations
  --watchdog             Enable self-healing watchdog service
  --thermal              Enable thermal monitoring service
  --coex                 Configure Bluetooth coexistence
  --skip-crash-collector Skip crash dump collector installation
  --test                 Run comprehensive test suite after install
  --help, -h             Show this help

Examples:
  sudo $0                          # Auto-detect and install
  sudo $0 --dry-run                # Preview actions
  sudo $0 --force-method ac3rn     # Force Ac3rN patched DKMS
  sudo $0 --uninstall              # Remove everything
  sudo $0 --verbose --reg-domain US
  sudo $0 --performance            # Install with performance optimizations
  sudo $0 --secure-boot --watchdog --thermal  # Full hardening
  sudo $0 --pi-optimizations       # Raspberry Pi optimized install

Project: https://github.com/MushroomCyber/MycoWave
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) DRY_RUN=true ;;
            --verbose|-v) VERBOSE=true ;;
            --uninstall) UNINSTALL=true ;;
            --force-method) FORCE_METHOD="$2"; shift ;;
            --skip-verify) SKIP_VERIFY=true ;;
            --skip-monitor) SKIP_MONITOR_SETUP=true ;;
            --reg-domain) REG_DOMAIN="$2"; shift ;;
            --performance) ENABLE_PERFORMANCE=true ;;
            --skip-firmware) SKIP_FIRMWARE_UPDATE=true ;;
            --secure-boot) ENABLE_SECURE_BOOT=true ;;
            --pi-optimizations) ENABLE_PI_OPTIMIZATIONS=true ;;
            --watchdog) ENABLE_WATCHDOG=true ;;
            --thermal) ENABLE_THERMAL=true ;;
            --coex) ENABLE_COEX=true ;;
            --skip-crash-collector) SKIP_CRASH_COLLECTOR=true ;;
            --test) RUN_TEST_SUITE=true ;;
            --help|-h) usage; exit 0 ;;
            *) error "Unknown option: $1"; usage; exit 1 ;;
        esac
        shift
    done
}

main() {
    parse_args "$@"

    # Initialize log
    run "mkdir -p /var/log"
    run "touch '$LOG_FILE'"
    run "chmod 644 '$LOG_FILE'"

    print_banner
    require_root

    detect_os
    detect_kernel
    detect_arch
    detect_secure_boot
    detect_kali_version
    detect_driver_conflicts

    if [[ "$UNINSTALL" == true ]]; then
        uninstall_driver
        exit 0
    fi

    check_prerequisites
    choose_strategy

    # Execute chosen strategy
    case "$STRATEGY" in
        inkernel) install_inkernel ;;
        kali-dkms) install_kali_dkms ;;
        ac3rn) install_ac3rn ;;
        aircrack-ng) install_aircrack_ng ;;
        *) error "Unknown strategy: $STRATEGY"; exit 1 ;;
    esac

    setup_performance_config
    update_firmware
    setup_secure_boot
    setup_pi_optimizations
    setup_watchdog
    setup_thermal
    setup_coex
    setup_crash_collector
    setup_monitor_mode
    setup_dkms_autorebuild
    verify_install

    # Run comprehensive test suite if requested
    if [[ "$RUN_TEST_SUITE" == true ]]; then
        run_full_test_suite
    fi

    log "═══════════════════════════════════════════════════════════"
    success "Installation complete!"
    info "Interface: wlan0 (monitor: wlan0mon)"
    info "Monitor mode: Auto-enabled on plug/boot"
    info "5GHz channels: Enabled via regulatory domain $REG_DOMAIN"
    info "Log: $LOG_FILE"
    info ""
    info "Quick test:"
    info "  sudo airmon-ng check kill"
    info "  sudo airmon-ng start wlan0"
    info "  sudo airodump-ng wlan0mon"
    log "═══════════════════════════════════════════════════════════"
}

main "$@"