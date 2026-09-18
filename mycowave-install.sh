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
MANIFEST_DIR="/var/lib/mycowave"
MANIFEST_FILE="$MANIFEST_DIR/installed.files"
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
REMOVE_MOK_KEYS=false
# Set false when the running kernel has no build tree; DKMS strategies are skipped.
KERNEL_HEADERS_AVAILABLE=true

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ─── Logging Helpers ────────────────────────────────────────────────────────
# In DRY_RUN mode file appends are skipped (stdout only) so a missing
# /var/log file or gated mkdir/touch cannot abort the run.
_log_emit() {
    local msg="$1"
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "$msg"
    else
        echo -e "$msg" | tee -a "$LOG_FILE"
    fi
}
log()     { _log_emit "${BLUE}[$(date '+%H:%M:%S')]${NC} $*"; }
info()    { _log_emit "${CYAN}[INFO]${NC} $*"; }
warn()    { _log_emit "${YELLOW}[WARN]${NC} $*"; }
error()   { _log_emit "${RED}[ERROR]${NC} $*"; }
success() { _log_emit "${GREEN}[OK]${NC} $*"; }
verbose() { [[ "$VERBOSE" == true ]] && log "$*" || true; }
run()     { verbose "→ $*"; [[ "$DRY_RUN" == true ]] || eval "$*"; }
# Artifact manifest: only files MycoWave itself creates are recorded, so
# --uninstall never deletes package-owned files (e.g. /etc/default/crda or
# linux-firmware blobs under /lib/firmware/rtlwifi/).
manifest_add() {
    local path="$1"
    [[ -n "$path" ]] || return 0
    if [[ "$DRY_RUN" == true ]]; then
        info "[dry-run] would record $path in $MANIFEST_FILE"
        return 0
    fi
    mkdir -p "$MANIFEST_DIR"
    grep -qxF "$path" "$MANIFEST_FILE" 2>/dev/null || printf '%s\n' "$path" >> "$MANIFEST_FILE"
}

manifest_has() {
    local path="$1"
    [[ -f "$MANIFEST_FILE" ]] && grep -qxF "$path" "$MANIFEST_FILE" 2>/dev/null
}

# Centralized file writer: respects DRY_RUN. Usage: dry_write DEST <<EOF ... EOF
dry_write() {
    local dest="$1"
    if [[ "$DRY_RUN" == true ]]; then
        info "[dry-run] would write $dest"
        cat >/dev/null
        return 0
    fi
    mkdir -p "$(dirname "$dest")"
    cat > "$dest"
    manifest_add "$dest"
}

# ─── Utility Functions ──────────────────────────────────────────────────────
require_root() {
    [[ $EUID -eq 0 ]] || { error "Run as root (sudo)"; exit 1; }
}

# Out-of-tree (DKMS) strategies need the build tree of the RUNNING kernel.
# Kali rolling often drops headers for older kernels, so fail fast and clearly
# instead of letting a downstream build/apt step produce a confusing error.
require_kernel_headers() {
    [[ "$DRY_RUN" == true ]] && return 0
    if [[ ! -d "/lib/modules/$(uname -r)/build" ]]; then
        error "Kernel headers for $(uname -r) are missing (/lib/modules/$(uname -r)/build)."
        error "An out-of-tree DKMS driver cannot be built for this kernel."
        error "Use the in-kernel driver instead: sudo $SCRIPT_NAME --force-method inkernel"
        return 1
    fi
    return 0
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

    lsmod | grep -q '^88XXau' && DKMS_LOADED=true || true
    lsmod | grep -q '^rtw88_8812au' && INKERNEL_LOADED=true || true

    if [[ "$DKMS_LOADED" == true && "$INKERNEL_LOADED" == true ]]; then
        CONFLICT_DETECTED=true
        warn "Driver conflict: both DKMS (88XXau) and in-kernel (rtw88_8812au) loaded"
    fi
    verbose "DKMS loaded: $DKMS_LOADED, In-kernel loaded: $INKERNEL_LOADED, Conflict: $CONFLICT_DETECTED"
}

# ─── Strategy Selection ─────────────────────────────────────────────────────
choose_strategy() {
    if [[ -n "$FORCE_METHOD" ]]; then
        STRATEGY="$FORCE_METHOD"
        case "$STRATEGY" in
            inkernel|lwfinger|ac3rn|aircrack-ng)
                ;;
            kali-dkms)
                # The Kali package is frozen at 2025-03-30 and fails to build on 6.15+.
                if (( KERNEL_MAJOR > 6 || (KERNEL_MAJOR == 6 && KERNEL_MINOR > 13) )); then
                    error "--force-method kali-dkms refused on kernel $KERNEL_VERSION (> 6.13)."
                    error "The Kali realtek-rtl88xxau-dkms package is frozen at 2025-03-30 and does not build on 6.15+."
                    error "Use --force-method ac3rn (6.15-6.18) or --force-method lwfinger (managed) instead."
                    exit 1
                fi
                ;;
            *)
                error "Unknown forced method: $STRATEGY"
                error "Valid methods: inkernel|lwfinger|kali-dkms|ac3rn|aircrack-ng"
                usage
                exit 1
                ;;
        esac
        info "Forced strategy: $STRATEGY"
        return
    fi

    # Disjoint ranges — check highest first so lower branches are not shadowed.
    # Kernel >= 6.19 / 7.x: no maintained out-of-tree driver supports these.
    if (( KERNEL_MAJOR > 6 || (KERNEL_MAJOR == 6 && KERNEL_MINOR >= 19) )); then
        STRATEGY="inkernel"
        warn "════════════════════════════════════════════════════════════════"
        warn "  Kernel $KERNEL_VERSION ≥ 6.19 → using in-kernel rtw88 (managed)"
        warn "  NO maintained out-of-tree rtl8812au driver supports 6.19+/7.x, and"
        warn "  Kali usually ships no headers for older kernels, so DKMS builds are"
        warn "  not possible. rtw88 supports managed + monitor mode; packet injection"
        warn "  is NOT guaranteed. Only if matching headers exist, try:"
        warn "      sudo $SCRIPT_NAME --force-method ac3rn"
        warn "════════════════════════════════════════════════════════════════"
        return
    fi

    # Kernel 6.15 - 6.18 → Ac3rN patched DKMS (fixes timer/cfg80211 API breaks)
    if (( KERNEL_MAJOR == 6 && KERNEL_MINOR >= 15 && KERNEL_MINOR <= 18 )); then
        STRATEGY="ac3rn"
        info "Kernel $KERNEL_VERSION (6.15-6.18) → using Ac3rN patched DKMS (fixes API breaks)"
        return
    fi

    # Kernel 6.14 (exactly) → in-kernel rtw88 (Linux 6.14 mac80211)
    if (( KERNEL_MAJOR == 6 && KERNEL_MINOR == 14 )); then
        STRATEGY="inkernel"
        info "Kernel $KERNEL_VERSION (6.14) → using in-kernel rtw88 driver"
        return
    fi

    # Kernel 6.6 - 6.13 → Kali DKMS package (frozen at 2025-03-30; safe on these kernels)
    if (( KERNEL_MAJOR == 6 && KERNEL_MINOR >= 6 && KERNEL_MINOR <= 13 )); then
        STRATEGY="kali-dkms"
        info "Kernel $KERNEL_VERSION (6.6-6.13) → using Kali DKMS package"
        return
    fi

    # Older kernels (< 6.6) → lwfinger/rtw88 managed backport (default).
    # aircrack-ng remains reachable via --force-method aircrack-ng for injection work.
    STRATEGY="lwfinger"
    info "Kernel $KERNEL_VERSION < 6.6 → using lwfinger/rtw88 backport (managed mode; injection NOT guaranteed)"
    info "For injection workloads use: sudo $SCRIPT_NAME --force-method aircrack-ng"
}

# ─── Pre-Install Checks ─────────────────────────────────────────────────────
check_prerequisites() {
    log "Checking prerequisites..."

    # Network probe (warn-only): TCP handshake to Kali archive, no ICMP needed.
    if command -v timeout >/dev/null 2>&1; then
        if timeout 8 bash -c '</dev/tcp/archive.kali.org/443' >/dev/null 2>&1; then
            verbose "Network probe OK (archive.kali.org:443 reachable)"
        else
            warn "Network probe failed (archive.kali.org:443 unreachable). Package installs may fail — continuing anyway."
        fi
    else
        warn "Cannot probe network (timeout missing) — continuing anyway."
    fi

    # Required packages
    local missing=()
    for pkg in git dkms build-essential libelf-dev; do
        dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed" || missing+=("$pkg")
    done

    # Kernel headers: exact headers preferred; fall back to meta-package (warn, not fail).
    local headers_exact="linux-headers-$(uname -r)"
    if [[ "$ARCH_TYPE" == "arm64" ]]; then
        # Raspberry Pi / generic ARM64
        if dpkg-query -W -f='${Status}' kalipi-kernel-headers 2>/dev/null | grep -q "ok installed"; then
            verbose "kalipi-kernel-headers already installed"
        elif dpkg-query -W -f='${Status}' linux-headers-arm64 2>/dev/null | grep -q "ok installed"; then
            warn "kalipi-kernel-headers not installed; generic linux-headers-arm64 present — continuing (Pi-specific builds may fail)."
        else
            warn "No ARM64 headers found; will try kalipi-kernel-headers (warn-only, install may fail on non-Pi)."
            missing+=("kalipi-kernel-headers")
        fi
    else
        if ! dpkg-query -W -f='${Status}' "$headers_exact" 2>/dev/null | grep -q "ok installed"; then
            warn "$headers_exact is not installed."
            warn "Kali rolling drops headers for older kernels; the 'linux-headers-amd64'"
            warn "meta pulls a NEWER kernel image, so it is NOT auto-installed here."
        fi
    fi

    # Definitive DKMS prerequisite: build tree for the RUNNING kernel.
    if [[ "$DRY_RUN" != true && ! -d "/lib/modules/$(uname -r)/build" ]]; then
        KERNEL_HEADERS_AVAILABLE=false
        warn "No build tree at /lib/modules/$(uname -r)/build — out-of-tree DKMS"
        warn "drivers cannot be built for this kernel; use in-kernel rtw88 instead."
    fi

    # Helpful tools/binaries (warn-only, never fatal)
    local tool=""
    for tool in iw ethtool lsusb openssl mokutil airmon-ng; do
        command -v "$tool" >/dev/null 2>&1 || warn "Optional tool '$tool' not found (install iw/ethtool/usbutils/openssl/mokutil/aircrack-ng as needed)."
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        info "Installing missing packages: ${missing[*]}"
        run "apt-get update -qq"
        if [[ "$DRY_RUN" == true ]]; then
            verbose "→ apt-get install -y ${missing[*]}"
        else
            # Install one-by-one: a single unknown package name must not abort
            # the whole apt transaction (which would skip dkms/libelf-dev too).
            local pkg
            for pkg in "${missing[@]}"; do
                apt-get install -y "$pkg" || warn "Failed to install '$pkg' — continuing."
            done
        fi
    fi
    success "Prerequisites satisfied"
}

# ─── Driver Installation Methods ────────────────────────────────────────────
install_inkernel() {
    log "Installing: In-kernel rtw88 driver (Linux ≥ 6.14)"

    # Blacklist DKMS driver to prevent conflict (single write = idempotent)
    dry_write /etc/modprobe.d/blacklist-rtl88xxau.conf <<'EOF'
blacklist 88XXau
blacklist 8812au
blacklist 8814au
EOF

    # Ensure rtw88 is not blacklisted
    run "rm -f /etc/modprobe.d/blacklist-rtw88.conf"
    run "update-initramfs -u"

    # Load module. Never abort on failure: the module may be absent on this
    # kernel, or already loaded/bound on a re-run. Give actionable guidance.
    if [[ "$DRY_RUN" != true ]] && ! modinfo rtw88_8812au >/dev/null 2>&1; then
        error "rtw88_8812au is NOT available in /lib/modules/$(uname -r)."
        error "Kernel $KERNEL_VERSION may not ship the driver, or the matching"
        error "linux-modules package is not installed. Check: modinfo rtw88_8812au"
        error "If unavailable, boot a kernel that provides it (e.g. 6.19.x) or"
        error "install headers for this kernel and use --force-method ac3rn."
        return 1
    fi
    run "modprobe rtw88_8812au" || true
    sleep 2

    # Verify (skipped in dry-run: module load is simulated)
    if [[ "$DRY_RUN" != true ]]; then
        if lsmod | grep -q '^rtw88_8812au'; then
            success "In-kernel rtw88_8812au loaded"
        else
            warn "rtw88_8812au did not load — the USB adapter may be unplugged or the"
            warn "module may already be bound. Verify: lsmod | grep rtw88"
        fi
    fi
}

install_kali_dkms() {
    log "Installing: Kali DKMS package (realtek-rtl88xxau-dkms)"

    require_kernel_headers || return 1

    run "apt-get update -qq"
    run "apt-get install -y realtek-rtl88xxau-dkms realtek-rtl8814au-dkms"

    # Blacklist in-kernel driver to prevent conflict (single write = idempotent)
    dry_write /etc/modprobe.d/blacklist-rtw88.conf <<'EOF'
blacklist rtw88_8812au
blacklist rtw88_8821au
blacklist rtw88_8814au
EOF
    # Clear the blacklist created by install_inkernel so the DKMS module can load
    run "rm -f /etc/modprobe.d/blacklist-rtl88xxau.conf"
    run "update-initramfs -u"

    run "modprobe 88XXau"
    sleep 2

    # Verify (skipped in dry-run: module load is simulated)
    if [[ "$DRY_RUN" != true ]]; then
        lsmod | grep -q '^88XXau' || { error "88XXau failed to load"; return 1; }
    fi
    success "Kali DKMS driver loaded"
}

install_ac3rn() {
    log "Installing: Ac3rN patched source build (kernel 6.15-6.18 fix)"

    require_kernel_headers || return 1

    local repo="https://github.com/Ac3rN/realtek-rtl88xxau-auto-installer.git"
    local dir="/tmp/realtek-rtl88xxau-auto-installer"
    # Upstream entrypoint is install_alfa_driver.sh (NOT install.sh).
    local entry="$dir/install_alfa_driver.sh"

    run "rm -rf '$dir'"
    run "git clone --depth 1 '$repo' '$dir'"

    # Resolve the real entrypoint (upstream file name may change).
    if [[ "$DRY_RUN" != true ]]; then
        if [[ ! -f "$entry" ]]; then
            local found=""
            found=$(find "$dir" -maxdepth 1 -type f -name '*install*.sh' -print -quit 2>/dev/null || true)
            if [[ -z "$found" ]]; then
                error "Ac3rN entrypoint not found in $dir (expected install_alfa_driver.sh)."
                error "Upstream layout changed or clone failed. Alternatives:"
                error "  sudo $SCRIPT_NAME --force-method inkernel     # managed rtw88 (recommended)"
                error "  sudo $SCRIPT_NAME --force-method aircrack-ng  # injection"
                run "rm -rf '$dir'"
                return 1
            fi
            entry="$found"
        fi
    fi
    run "chmod +x '$entry'"

    # Build FIRST. Do not blacklist the working in-kernel driver until the
    # out-of-tree module actually builds — otherwise a failed build leaves the
    # adapter dead after reboot.
    if ! run "bash '$entry'"; then
        error "Ac3rN installer failed — rolling back so the in-kernel driver keeps working."
        local f
        for f in /etc/modprobe.d/*.conf; do
            [[ -f "$f" ]] || continue
            grep -qE '^[[:space:]]*blacklist[[:space:]]+rtw_' "$f" 2>/dev/null && run "rm -f '$f'"
        done
        run "rm -rf '$dir'"
        run "update-initramfs -u"
        error "Out-of-tree build unavailable on kernel $KERNEL_VERSION (missing/mismatched headers)."
        error "The in-kernel rtw88 driver works for managed + monitor mode:"
        error "    sudo $SCRIPT_NAME --force-method inkernel"
        return 1
    fi

    # Build succeeded → blacklist in-kernel rtw88 so 88XXau binds the device.
    dry_write /etc/modprobe.d/blacklist-rtw88.conf <<'EOF'
blacklist rtw88_8812au
blacklist rtw88_8821au
blacklist rtw88_8814au
EOF
    # Clear the blacklist created by install_inkernel so the DKMS module can load
    run "rm -f /etc/modprobe.d/blacklist-rtl88xxau.conf"
    run "update-initramfs -u"

    run "modprobe -r rtw88_8812au" || true
    run "modprobe 88XXau"
    sleep 2

    # Verify (skipped in dry-run: module load is simulated)
    if [[ "$DRY_RUN" != true ]]; then
        lsmod | grep -q '^88XXau' || { error "88XXau failed to load after Ac3rN install"; return 1; }
    fi
    success "Ac3rN patched DKMS driver loaded"
}

install_aircrack_ng() {
    log "Installing: aircrack-ng rtl8812au (latest source)"

    require_kernel_headers || return 1

    local repo="https://github.com/aircrack-ng/rtl8812au.git"
    local dir="/tmp/rtl8812au"

    run "rm -rf '$dir'"
    run "git clone --depth 1 '$repo' '$dir'"

    # Build FIRST; only blacklist the working in-kernel driver on success.
    local build_ok=true
    if [[ -f "$dir/dkms-install.sh" ]]; then
        run "'$dir/dkms-install.sh'" || build_ok=false
    else
        run "cd '$dir' && make dkms_install" || build_ok=false
    fi
    if [[ "$build_ok" != true ]]; then
        error "aircrack-ng build failed — the in-kernel driver is left unblacklisted."
        run "rm -rf '$dir'"
        error "For managed use: sudo $SCRIPT_NAME --force-method inkernel"
        return 1
    fi

    # Build succeeded → blacklist in-kernel rtw88 so 88XXau binds the device.
    dry_write /etc/modprobe.d/blacklist-rtw88.conf <<'EOF'
blacklist rtw88_8812au
blacklist rtw88_8821au
blacklist rtw88_8814au
EOF
    # Clear the blacklist created by install_inkernel so the DKMS module can load
    run "rm -f /etc/modprobe.d/blacklist-rtl88xxau.conf"
    run "update-initramfs -u"

    run "modprobe -r rtw88_8812au" || true
    run "modprobe 88XXau"
    sleep 2

    # Verify (skipped in dry-run: module load is simulated)
    if [[ "$DRY_RUN" != true ]]; then
        lsmod | grep -q '^88XXau' || { error "88XXau failed to load"; return 1; }
    fi
    success "aircrack-ng DKMS driver loaded"
}

install_lwfinger() {
    log "Installing: lwfinger/rtw88 backport (managed mode; injection NOT guaranteed)"

    require_kernel_headers || return 1

    local repo="https://github.com/lwfinger/rtw88.git"
    local dir="/tmp/rtw88"

    run "rm -rf '$dir'"
    run "git clone --depth 1 '$repo' '$dir'"

    # Repo ships CRLF dkms.conf — normalize before dkms reads it.
    run "sed -i 's/\r\$//' '$dir/dkms.conf'"

    # Build + register the rtw88 DKMS module.
    run "cd '$dir' && dkms install \"\$PWD\""
    run "make -C '$dir' install_fw"

    # Ship the module options file as-is, then blacklist the opposing DKMS driver.
    run "cp -f '$dir/rtw88.conf' /etc/modprobe.d/rtw88.conf"
    manifest_add /etc/modprobe.d/rtw88.conf

    dry_write /etc/modprobe.d/blacklist-rtl88xxau.conf <<'EOF'
blacklist 88XXau
blacklist 8812au
blacklist 8814au
EOF

    # Ensure rtw88 is not blacklisted (e.g. left over from a prior DKMS install).
    run "rm -f /etc/modprobe.d/blacklist-rtw88.conf"
    run "update-initramfs -u"

    run "modprobe rtw88_8812au"
    sleep 2

    # Verify (skipped in dry-run: module load is simulated)
    if [[ "$DRY_RUN" != true ]]; then
        lsmod | grep -q '^rtw88_8812au' || { error "rtw88_8812au failed to load"; return 1; }
    fi
    success "lwfinger/rtw88 driver loaded (managed mode; injection NOT guaranteed)"
}

# ─── Performance Configuration ──────────────────────────────────────────────
setup_performance_config() {
    [[ "$ENABLE_PERFORMANCE" != true ]] && { info "Performance optimizations disabled (use --performance)"; return; }

    log "Applying performance optimizations..."

    # Idempotency: remove any previous config so repeated runs never duplicate lines.
    run "rm -f /etc/modprobe.d/awus036ach-performance.conf"

    if [[ "$STRATEGY" == "inkernel" || "$STRATEGY" == "lwfinger" ]]; then
        # In-kernel / lwfinger rtw88: only rtw88_* options are valid here.
        # DKMS-only opts (rtw_switch_usb_mode, rtw_tx_pwr_idx_override,
        # rtw_monitor_*, rtw_country_code, rtw_ips_mode) are NOT valid for rtw88.
        dry_write /etc/modprobe.d/awus036ach-performance.conf <<EOF
# ─── AWUS036ACH Performance Optimizations (in-kernel rtw88) ───────────
# Generated by $SCRIPT_NAME v$SCRIPT_VERSION on $(date)

# rtw88 (in-kernel) specific options (mac80211 stack)
options rtw88_core debug_mask=0x0
options rtw88_core disable_lps_deep_mode=Y

# Regulatory domain is handled via cfg80211 (iw reg set $REG_DOMAIN),
# not via module options, for the in-kernel driver.

# ──────────────────────────────────────────────────────────────────────
EOF
    else
        # DKMS driver (88XXau): vendor-style rtw_* options only.
        dry_write /etc/modprobe.d/awus036ach-performance.conf <<EOF
# ─── AWUS036ACH Performance Optimizations (DKMS 88XXau) ───────────────
# Generated by $SCRIPT_NAME v$SCRIPT_VERSION on $(date)

# Force USB 2.0 mode (stability > speed for RTL8812AU chipset)
options 88XXau rtw_switch_usb_mode=2

# Disable power save (prevents monitor mode drops and disconnects)
options 88XXau rtw_ips_mode=0 rtw_lps_level=0

# TX power override (commx/dernyn fork, aircrack-ng v4.3.21+)
options 88XXau rtw_tx_pwr_idx_override=30

# Monitor mode optimizations (aircrack-ng fork)
options 88XXau rtw_monitor_disable_1m=1
options 88XXau rtw_monitor_retransmit=1

# Regulatory domain: Bolivia (full 5GHz channels, high power)
options 88XXau rtw_country_code=BO

# ──────────────────────────────────────────────────────────────────────
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
    if dpkg-query -W -f='${Status}' linux-firmware 2>/dev/null | grep -q "ok installed"; then
        local installed_version=$(dpkg-query -W -f='${Version}' linux-firmware 2>/dev/null || echo "unknown")
        verbose "linux-firmware version: $installed_version"

        # Copy firmware if available in package (cmp reads are safe;
        # all writes go through run() so DRY_RUN changes nothing).
        for fw in "${fw_files[@]}"; do
            if [[ "$DRY_RUN" == true ]]; then
                verbose "[dry-run] would compare/copy /lib/firmware/$fw → $fw_dir/"
                continue
            fi
            if [[ -f "/lib/firmware/$fw" ]] && ! cmp -s "/lib/firmware/$fw" "$fw_dir/$fw" 2>/dev/null; then
                run "cp -f '/lib/firmware/$fw' '$fw_dir/'"
                manifest_add "$fw_dir/$fw"
                updated=true
                info "Updated firmware: $fw"
            fi
        done
    fi

    # Also check for rtw88 firmware in /usr/lib/firmware (some distros)
    if [[ -d "/usr/lib/firmware/rtlwifi" ]]; then
        for fw in "${fw_files[@]}"; do
            if [[ "$DRY_RUN" == true ]]; then
                verbose "[dry-run] would compare/copy /usr/lib/firmware/rtlwifi/$fw → $fw_dir/"
                continue
            fi
            if [[ -f "/usr/lib/firmware/rtlwifi/$fw" ]] && ! cmp -s "/usr/lib/firmware/rtlwifi/$fw" "$fw_dir/$fw" 2>/dev/null; then
                run "cp -f '/usr/lib/firmware/rtlwifi/$fw' '$fw_dir/'"
                manifest_add "$fw_dir/$fw"
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
# PRE step: must run BEFORE the driver/DKMS install so keys exist first.
# Signing happens in setup_secure_boot_post() AFTER the driver install.
setup_secure_boot() {
    [[ "$ENABLE_SECURE_BOOT" != true ]] && { info "Secure Boot automation disabled (use --secure-boot)"; return; }

    log "Setting up Secure Boot MOK automation (pre-install: keys first)..."

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
        manifest_add "$script_dst"
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

# Post-install Secure Boot step: sign freshly built DKMS modules.
# Runs AFTER the driver install so there is something to sign.
setup_secure_boot_post() {
    [[ "$ENABLE_SECURE_BOOT" != true ]] && return 0

    log "Signing DKMS modules for Secure Boot..."

    local mok_dir="/var/lib/shim-signed/mok"
    local mok_key="$mok_dir/MOK.priv"
    local mok_cert="$mok_dir/MOK.der"

    if [[ ! -f "$mok_key" || ! -f "$mok_cert" ]]; then
        warn "MOK key/cert missing — skipping signing (pre step should have created them)."
        return 0
    fi

    local kver; kver="$(uname -r)"
    local sign_file="/lib/modules/$kver/build/scripts/sign-file"
    if [[ ! -x "$sign_file" ]]; then
        warn "sign-file not found at $sign_file (install linux-headers-$(uname -r) or the headers meta-package) — skipping signing."
        warn "Unsigned DKMS modules will fail to load with Secure Boot enabled."
        return 0
    fi

    local signed_any=false
    local ko=""
    while IFS= read -r ko; do
        [[ -z "$ko" ]] && continue
        # sign-file cannot sign compressed modules; skip .ko.zst explicitly.
        if [[ "$ko" == *.ko.zst ]]; then
            warn "Skipping compressed module $ko (sign-file cannot sign .ko.zst; decompress with unzstd and re-run, or disable module compression)."
            continue
        fi
        if [[ "$ko" != *.ko ]]; then
            verbose "Skipping non-.ko artifact: $ko"
            continue
        fi
        if [[ "$DRY_RUN" == true ]]; then
            verbose "[dry-run] would sign $ko"
        else
            "$sign_file" sha256 "$mok_key" "$mok_cert" "$ko" \
                && { info "Signed: $ko"; signed_any=true; } \
                || warn "Failed to sign $ko"
        fi
    done < <(find "/lib/modules/$kver/updates/dkms" \( -name '88XXau.ko' -o -name '88XXau.ko.zst' \) 2>/dev/null || true)

    if [[ "$signed_any" == true ]]; then
        success "DKMS modules signed with MOK key"
    else
        warn "No uncompressed DKMS modules found to sign under /lib/modules/$kver/updates/dkms (or dry-run)."
    fi

    # Persist DKMS signing config so kernel-upgrade rebuilds are auto-signed.
    persist_dkms_signing_config "$mok_key" "$mok_cert" "$sign_file"

    info "DKMS will auto-rebuild on kernel upgrades (dkms autoinstall); signing is now configured for future rebuilds."
    info "REBOOT REQUIRED: enroll the MOK key first (sudo mycowave-enroll-mok enroll), then reboot."
}

# Persist mok_signing_key/mok_certificate/sign_file for DKMS. Newer DKMS reads
# /etc/dkms/framework.conf.d/*.conf; older versions use /etc/dkms/framework.conf.
persist_dkms_signing_config() {
    local mok_key="$1"
    local mok_cert="$2"
    local sign_file="$3"

    local conf_block
    conf_block="# MycoWave signing (managed) - auto-generated for kernel-upgrade rebuilds
mok_signing_key=\"$mok_key\"
mok_certificate=\"$mok_cert\"
sign_file=\"$sign_file\"
# sign_tool is optional; DKMS defaults to /etc/dkms/sign_helper.sh when unset.
# End MycoWave signing"

    if [[ -d /etc/dkms/framework.conf.d ]]; then
        dry_write /etc/dkms/framework.conf.d/mycowave-signing.conf <<EOF
$conf_block
EOF
        success "DKMS signing config written to /etc/dkms/framework.conf.d/mycowave-signing.conf"
    else
        info "Creating DKMS signing config in /etc/dkms/framework.conf"
        if [[ "$DRY_RUN" == true ]]; then
            info "[dry-run] would append MycoWave signing config to /etc/dkms/framework.conf"
        else
            mkdir -p /etc/dkms
            touch /etc/dkms/framework.conf
            # Idempotent: drop any previous MycoWave block before appending.
            sed -i '/^# MycoWave signing (managed)/,/^# End MycoWave signing/d' /etc/dkms/framework.conf 2>/dev/null || true
            printf '%s\n' "$conf_block" >> /etc/dkms/framework.conf
            # NOTE: /etc/dkms/framework.conf is shared/package-owned — do NOT
            # record it in the manifest; uninstall strips only our block.
            success "DKMS signing config appended to /etc/dkms/framework.conf"
        fi
    fi
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
        manifest_add "$script_dst"
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
        manifest_add "$script_dst"
        success "Installed watchdog script to $script_dst"
    else
        warn "wifi-watchdog.sh not found at $script_src"
    fi

    # Install systemd service
    local svc_src="$(dirname "${BASH_SOURCE[0]}")/scripts/mycowave-watchdog.service"
    local svc_dst="/etc/systemd/system/mycowave-watchdog.service"

    if [[ -f "$svc_src" ]]; then
        run "cp '$svc_src' '$svc_dst'"
        manifest_add "$svc_dst"
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
        manifest_add "$nm_dst"
        success "Installed NetworkManager dispatcher for crash detection"
    else
        warn "99-mycowave-wifi-recover not found at $nm_src"
    fi

    # Enable and start (idempotent: skip if already enabled/active)
    run "systemctl daemon-reload"
    if systemctl is-enabled mycowave-watchdog.service >/dev/null 2>&1; then
        verbose "mycowave-watchdog.service already enabled"
    else
        run "systemctl enable mycowave-watchdog.service"
    fi
    if systemctl is-active mycowave-watchdog.service >/dev/null 2>&1; then
        verbose "mycowave-watchdog.service already active"
    else
        run "systemctl start mycowave-watchdog.service"
    fi

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
        manifest_add "$script_dst"
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
        inkernel|lwfinger) driver_module="rtw88_core" ;;
        kali-dkms|ac3rn|aircrack-ng) driver_module="88XXau" ;;
    esac

    local coex_src="$(dirname "${BASH_SOURCE[0]}")/scripts/mycowave-coex.conf"

    if [[ "$STRATEGY" == "inkernel" || "$STRATEGY" == "lwfinger" ]]; then
        # rtw88 (in-kernel/lwfinger) exposes a runtime coex parameter — emit it ACTIVE.
        local btcoex=0
        [[ "$has_bt" == true ]] && btcoex=1
        dry_write /etc/modprobe.d/mycowave-coex.conf <<EOF
# MycoWave - Bluetooth Coexistence Configuration (rtw88)
# Generated by $SCRIPT_NAME v$SCRIPT_VERSION on $(date)
# Active driver: $driver_module (strategy: $STRATEGY)
# Internal BT detected: $has_bt
# Reference template: $coex_src
#
# Runtime coexistence toggle for the in-kernel / lwfinger rtw88 stack:
options rtw88_core rtw_btcoex_enable=$btcoex
# Antenna sharing (0=dedicated, 1=shared; check EFUSE) — uncomment to tune:
# options rtw88_core rtw_btcoex_ant_num=0
EOF
        if [[ "$has_bt" == true ]]; then
            info "Internal Bluetooth detected - coexistence ENABLED (rtw_btcoex_enable=1)"
        else
            info "No internal Bluetooth - coexistence DISABLED (rtw_btcoex_enable=0)"
        fi
    else
        # DKMS 88XXau has no runtime coex option (CONFIG_RTW_COEX is compile-time);
        # keep the shipped template (all comments) as reference only.
        if [[ -f "$coex_src" ]]; then
            if [[ "$DRY_RUN" == true ]]; then
                info "[dry-run] would copy reference template $coex_src → /etc/modprobe.d/mycowave-coex.conf"
            else
                mkdir -p /etc/modprobe.d
                cp "$coex_src" /etc/modprobe.d/mycowave-coex.conf
                manifest_add /etc/modprobe.d/mycowave-coex.conf
            fi
        else
            dry_write /etc/modprobe.d/mycowave-coex.conf <<EOF
# MycoWave - Bluetooth Coexistence Configuration (DKMS reference)
# Generated on $(date)
# Driver: $driver_module — runtime coex is not supported; compile-time CONFIG_RTW_COEX only.
EOF
        fi
        info "DKMS driver ($driver_module) - coexistence is compile-time only (CONFIG_RTW_COEX); not applicable at runtime"
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
        manifest_add "$script_dst"
        success "Installed crash collector script to $script_dst"
    else
        warn "collect-crash.sh not found at $script_src"
    fi

    # Create systemd timer for periodic collection (optional)
    dry_write /etc/systemd/system/mycowave-crash-collector.timer <<'EOF'
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

    dry_write /etc/systemd/system/mycowave-crash-collector.service <<'EOF'
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
    if systemctl is-enabled mycowave-crash-collector.timer >/dev/null 2>&1; then
        verbose "mycowave-crash-collector.timer already enabled"
    else
        run "systemctl enable mycowave-crash-collector.timer"
    fi
    if systemctl is-active mycowave-crash-collector.timer >/dev/null 2>&1; then
        verbose "mycowave-crash-collector.timer already active"
    else
        run "systemctl start mycowave-crash-collector.timer"
    fi

    success "Crash collector installed with hourly timer"
}

# ─── Post-Install Configuration ─────────────────────────────────────────────
setup_monitor_mode() {
    [[ "$SKIP_MONITOR_SETUP" == true ]] && { info "Skipping monitor mode setup"; return; }

    log "Configuring automatic monitor mode..."
    warn "Monitor setup renames 88XXau/rtw88_8812au interfaces to wlan0 and the boot-time"
    warn "service runs 'airmon-ng check kill' (kills NetworkManager). On multi-NIC systems"
    warn "this can disrupt other interfaces — re-run with --skip-monitor to opt out."

    # 1. Create udev rule for consistent interface naming
    dry_write /etc/udev/rules.d/90-awus036ach.rules <<'EOF'
# Alpha AWUS036ACH - consistent naming
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="88XXau", NAME="wlan0"
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="rtw88_8812au", NAME="wlan0"
EOF

    # 2. Create NetworkManager dispatcher to auto-enable monitor mode on plug
    dry_write /etc/NetworkManager/dispatcher.d/99-awus036ach-monitor <<'EOF'
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
    dry_write /etc/systemd/system/awus036ach-monitor.service <<'EOF'
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
    if systemctl is-enabled awus036ach-monitor.service >/dev/null 2>&1; then
        verbose "awus036ach-monitor.service already enabled"
    else
        run "systemctl enable awus036ach-monitor.service"
    fi

    # 4. Regulatory domain for 5GHz channels
    run "iw reg set $REG_DOMAIN"
    dry_write /etc/default/crda <<EOF
REGDOMAIN=$REG_DOMAIN
EOF

    success "Monitor mode automation configured"
}

setup_dkms_autorebuild() {
    # In-kernel strategy needs no DKMS rebuild machinery or early module probe.
    if [[ "$STRATEGY" == "inkernel" ]]; then
        info "In-kernel strategy: skipping DKMS auto-rebuild (no DKMS modules, no initramfs hook needed)"
        return 0
    fi

    log "Configuring DKMS auto-rebuild on kernel upgrade..."

    # Ensure dkms service is enabled (idempotent)
    if systemctl is-enabled dkms.service >/dev/null 2>&1; then
        verbose "dkms.service already enabled"
    else
        run "systemctl enable dkms.service 2>/dev/null || true"
    fi

    # Create hook for initramfs update (ensures driver in initramfs for early boot)
    dry_write /etc/initramfs-tools/scripts/init-top/awus036ach <<'EOF'
#!/bin/sh
# Load AWUS036ACH driver early for initramfs
modprobe 88XXau 2>/dev/null || modprobe rtw88_8812au 2>/dev/null || true
EOF
    run "chmod +x /etc/initramfs-tools/scripts/init-top/awus036ach"
    run "update-initramfs -u"

    success "DKMS auto-rebuild configured"
}

# Detect the real monitor-mode interface. Modern airmon-ng enables monitor mode
# IN PLACE (keeping the original name) and does not necessarily create <iface>mon.
# Prints the detected monitor interface, or the managed interface as a fallback
# (in-place monitor mode / monitor not yet enabled). Never invents a name.
detect_monitor_iface() {
    local managed_iface="${1:-}"
    local detected=""
    detected=$(iw dev 2>/dev/null | awk '/Interface/{i=$2} /type monitor/{print i; exit}')
    if [[ -n "$detected" ]]; then
        printf '%s\n' "$detected"
    else
        printf '%s\n' "$managed_iface"
    fi
}

# ─── Verification ───────────────────────────────────────────────────────────
verify_install() {
    [[ "$SKIP_VERIFY" == true ]] && { info "Skipping verification"; return; }

    # Smoke check only: module + interface. Deeper checks (monitor mode,
    # injection, channels) live in the --test suite. Never kills NetworkManager here.
    log "Verifying installation (smoke: module + interface)..."

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

    # Accept either a renamed or in-place monitor interface (resolved dynamically).
    local mon_iface; mon_iface=$(detect_monitor_iface "$iface")
    if [[ "$mon_iface" == "$iface" ]]; then
        verbose "Monitor interface: $iface (in-place, once monitor mode is enabled)"
    else
        info "Monitor interface: $mon_iface"
    fi

    # Check module loaded
    if ! lsmod | grep -qE '^(88XXau|rtw88_8812au)'; then
        error "No driver module loaded"
        return 1
    fi

    success "Smoke verification passed (module loaded, $iface present)"
    info "Run with --test for full checks (monitor mode, injection, 5GHz, VHT/HT)"
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

    # Resolve the phy for this interface (never assume phy0).
    local phy=""
    if [[ -f "/sys/class/net/$iface/phy80211/name" ]]; then
        phy=$(cat "/sys/class/net/$iface/phy80211/name" 2>/dev/null || echo "")
    fi
    [[ -z "$phy" ]] && phy="phy0"
    verbose "Suite: iface=$iface phy=$phy"

    # Expected module derived from the chosen strategy (explicit, no globals).
    local expected_module=""
    case "$STRATEGY" in
        inkernel|lwfinger) expected_module="rtw88_8812au" ;;
        kali-dkms|ac3rn|aircrack-ng) expected_module="88XXau" ;;
        *) expected_module="88XXau" ;;
    esac

    # Injection check outcome (OK|FAILED|SKIPPED) reported in the final summary.
    local inj_status="SKIPPED"

    # NOTE: every run_test call ends with || true so a failing test never
    # aborts the suite under set -e; the summary below is always reached.

    # Test 1: Driver loaded & version
    run_test "Driver module loaded" "lsmod | grep -qE '^(88XXau|rtw88_8812au)'" || true

    # Test 2: Interface up
    run_test "Interface $iface exists" "[[ -e /sys/class/net/$iface ]]" || true

    # Test 3: Interface carrier (link detection capability)
    run_test "Interface has carrier detection" "ethtool $iface 2>/dev/null | grep -q 'Link detected'" || true

    # Test 4: TX power setting (real check — no || true inside the probe)
    run_test "TX power configurable" "iw dev $iface set txpower fixed 2000" || true

    # Test 5: Regulatory domain
    local reg=$(iw reg get 2>/dev/null | grep -i country | head -1 | awk '{print $2}' || echo "00")
    run_test "Regulatory domain set ($reg)" "[[ '$reg' != '00' ]]" || true

    # Test 6: Channel list populated
    run_test "Channel list available" "iw phy $phy channels 2>/dev/null | grep -q MHz" || true

    # Test 7: 5GHz channels present (grep -c prints 0 with exit 1 on no match;
    # use || true so output stays a single clean number for arithmetic)
    local ch5; ch5=$(iw phy "$phy" channels 2>/dev/null | grep -c "5[0-9][0-9][0-9]" || true)
    ch5=$(printf '%s' "$ch5" | head -n1 | tr -cd '0-9')
    [[ -z "$ch5" ]] && ch5=0
    run_test "5GHz channels available ($ch5)" "[[ $ch5 -gt 0 ]]" || true

    # Test 8: VHT capabilities (802.11ac)
    run_test "VHT (802.11ac) supported" "iw phy $phy info 2>/dev/null | grep -qi vht" || true

    # Test 9: HT capabilities (802.11n)
    run_test "HT (802.11n) supported" "iw phy $phy info 2>/dev/null | grep -qi ht" || true

    # Test 10: Monitor mode. Modern airmon-ng enables monitor mode IN PLACE and
    # may keep the original interface name instead of creating <iface>mon.
    run_test "Monitor mode works" "airmon-ng check kill >/dev/null 2>&1 && airmon-ng start $iface >/dev/null 2>&1" || true

    # Test 11: Monitor interface present — accepts a renamed OR in-place monitor interface.
    local mon_iface=""
    local mon_is_monitor=false
    mon_iface=$(iw dev 2>/dev/null | awk '/Interface/{i=$2} /type monitor/{print i; exit}')
    if [[ -n "$mon_iface" && -e "/sys/class/net/$mon_iface" ]]; then
        mon_is_monitor=true
    else
        mon_iface="$iface"   # in-place fallback for cleanup/guidance only
    fi
    run_test "Monitor interface present ($mon_iface)" "[[ '$mon_is_monitor' == true ]]" || true

    # Test 11b: Real injection capability via aireplay-ng (non-fatal).
    if [[ "$mon_is_monitor" != true ]]; then
        warn "Injection test SKIPPED (no monitor-mode interface found via 'iw dev')"
    elif ! command -v aireplay-ng >/dev/null 2>&1; then
        warn "Injection test SKIPPED (aireplay-ng not installed)"
    elif aireplay-ng -9 "$mon_iface" >/dev/null 2>&1; then
        inj_status="OK"
        success "✓ Injection capability (aireplay-ng -9 $mon_iface)"
    else
        inj_status="FAILED"
        error "✗ Injection capability (aireplay-ng -9 $mon_iface)"
        all_passed=false
    fi

    # Test 12: Cleanup monitor
    run_test "Monitor cleanup works" "airmon-ng stop $mon_iface >/dev/null 2>&1" || true

    # Test 13: USB device responsive
    run_test "USB device responsive" "lsusb -d 0bda:a811 2>/dev/null | grep -q Realtek" || true

    # Test 14: No driver conflict
    run_test "No driver conflict (single driver)" "! (lsmod | grep -q '^88XXau' && lsmod | grep -q '^rtw88_8812au')" || true

    # Test 15: Module parameters applied (if performance enabled)
    if [[ "$ENABLE_PERFORMANCE" == true ]]; then
        run_test "Module parameters directory accessible ($expected_module)" "[[ -d /sys/module/$expected_module/parameters ]]" || true
    fi

    # Test 16: Firmware loaded
    run_test "Firmware files present" "ls /lib/firmware/rtlwifi/rtw8812a_fw.bin 2>/dev/null || ls /lib/firmware/rtw8812a_fw.bin 2>/dev/null" || true

    # Test 17: Thermal zone accessible (if thermal enabled)
    if [[ "$ENABLE_THERMAL" == true ]]; then
        run_test "Thermal monitoring accessible" "[[ -d /sys/kernel/debug/rtw88 ]] || [[ -d /sys/class/thermal ]]" || true
    fi

    # Test 18: Watchdog service active (if watchdog enabled)
    if [[ "$ENABLE_WATCHDOG" == true ]]; then
        run_test "Watchdog service active" "systemctl is-active mycowave-watchdog.service 2>/dev/null | grep -q active" || true
    fi

    # Test 19: Crash collector timer (if enabled)
    if [[ "$SKIP_CRASH_COLLECTOR" != true ]]; then
        run_test "Crash collector timer enabled" "systemctl is-enabled mycowave-crash-collector.timer 2>/dev/null | grep -q enabled" || true
    fi

    # Test 20: udev rules installed
    run_test "udev rules installed" "[[ -f /etc/udev/rules.d/90-awus036ach.rules ]]" || true

    # Explicit capability summary (managed vs injection).
    local managed_status="FAILED"
    if lsmod 2>/dev/null | grep -qE '^(88XXau|rtw88_8812au)' && [[ -e "/sys/class/net/$iface" ]]; then
        managed_status="OK"
    fi
    info "managed: $managed_status | injection: $inj_status"

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

    # Remove MycoWave-created artifacts recorded at install time. This is the
    # authoritative list: package-owned files are only present if MycoWave
    # itself created/overwrote them.
    if [[ "$DRY_RUN" == true ]]; then
        info "[dry-run] would remove paths recorded in $MANIFEST_FILE"
    elif [[ -f "$MANIFEST_FILE" ]]; then
        local recorded=""
        while IFS= read -r recorded; do
            [[ -n "$recorded" ]] || continue
            run "rm -f '$recorded'"
        done < "$MANIFEST_FILE"
    fi

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
    run "rm -f /etc/modprobe.d/rtw88.conf"

    # Strip only the MycoWave signing block from the shared DKMS framework.conf.
    if [[ -f /etc/dkms/framework.conf ]]; then
        run "sed -i '/^# MycoWave signing (managed)/,/^# End MycoWave signing/d' /etc/dkms/framework.conf"
    fi

    # Remove scripts
    run "rm -f /usr/local/bin/mycowave-enroll-mok"
    run "rm -f /usr/local/bin/mycowave-pi-optimizations"
    run "rm -f /usr/local/bin/wifi-watchdog"
    run "rm -f /usr/local/bin/thermal-monitor"
    run "rm -f /usr/local/bin/mycowave-collect-crash"

    # Remove multi-user.target.wants symlinks left by service enables
    run "rm -f /etc/systemd/system/multi-user.target.wants/awus036ach-monitor.service"
    run "rm -f /etc/systemd/system/multi-user.target.wants/mycowave-watchdog.service"
    run "rm -f /etc/systemd/system/multi-user.target.wants/mycowave-thermal.service"
    run "rm -f /etc/systemd/system/multi-user.target.wants/mycowave-cpu-governor.service"
    run "rm -f /etc/systemd/system/timers.target.wants/mycowave-crash-collector.timer"

    # MOK keys: warn-only by default — the UEFI enrollment persists regardless.
    if [[ "$REMOVE_MOK_KEYS" == true ]]; then
        run "rm -rf /var/lib/shim-signed/mok"
        warn "MOK keys deleted. NOTE: the UEFI key enrollment REMAINS in firmware — remove it via your UEFI MOK Manager if needed."
    else
        warn "MOK keys KEPT at /var/lib/shim-signed/mok (UEFI enrollment remains). Re-run with --remove-mok to delete them."
    fi

    # Remove crash dumps
    run "rm -rf /var/log/mycowave-crashes"

    # Unload modules
    run "modprobe -r 88XXau 2>/dev/null || true"
    run "modprobe -r 8812au 2>/dev/null || true"
    run "modprobe -r 8814au 2>/dev/null || true"
    run "modprobe -r rtw88_8812au 2>/dev/null || true"
    run "modprobe -r rtw88_8821au 2>/dev/null || true"
    run "modprobe -r rtw88_8814au 2>/dev/null || true"

    # Remove DKMS modules (correct names: rtl88xxau/88XXau, rtl8814au)
    run "dkms remove -m rtl88xxau -v all --all 2>/dev/null || true"
    run "dkms remove -m 88XXau -v all --all 2>/dev/null || true"
    run "dkms remove -m rtl8814au -v all --all 2>/dev/null || true"
    run "dkms remove -m rtl8812au -v all --all 2>/dev/null || true"
    run "apt-get purge -y realtek-rtl88xxau-dkms realtek-rtl8814au-dkms 2>/dev/null || true"

    # Remove leftover DKMS sources, installer clones, regdomain, firmware copies
    run "rm -rf /usr/src/rtl88xxau-* /usr/src/rtl8812au-* /usr/src/rtl8814au-*"
    run "rm -rf /tmp/realtek-rtl88xxau-auto-installer /tmp/rtl8812au /tmp/rtw88"

    # /etc/default/crda is package-owned (crda): only remove if MycoWave created it.
    if manifest_has /etc/default/crda; then
        run "rm -f /etc/default/crda"
    elif [[ -e /etc/default/crda ]]; then
        warn "Keeping /etc/default/crda (not created by MycoWave; package-owned by crda). Remove manually if desired."
    fi

    # Firmware blobs under /lib/firmware/rtlwifi are package-owned (linux-firmware):
    # only remove copies MycoWave itself installed.
    local fw_candidate=""
    for fw_candidate in \
        /lib/firmware/rtlwifi/rtw8812a_fw.bin \
        /lib/firmware/rtlwifi/rtw8821a_fw.bin \
        /lib/firmware/rtlwifi/rtw8812b_fw.bin; do
        if manifest_has "$fw_candidate"; then
            run "rm -f '$fw_candidate'"
        elif [[ -e "$fw_candidate" ]]; then
            warn "Keeping $fw_candidate (not created by MycoWave; package-owned by linux-firmware)."
        fi
    done

    # Drop the manifest last (its own directory is MycoWave-owned).
    run "rm -rf '$MANIFEST_DIR'"

    success "Uninstall complete. Reboot recommended."
}

# ─── Main ───────────────────────────────────────────────────────────────────
print_banner() {
    cat <<'EOF'
╔═══════════════════════════════════════════════════════════════════════╗
║                    MycoWave v2.2.0                                    ║
║       Alpha AWUS036ACH Driver Installer for Kali Linux              ║
╠═══════════════════════════════════════════════════════════════════════╣
║  Smart installer supporting:                                        ║
║  • Kali 2024.x - 2026.1+ (Kernel 6.6 - 7.x; 6.19+ unmaintained)    ║
║  • Strategies: lwfinger rtw88, ac3rn, kali-dkms, aircrack-ng       ║
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
  --force-method METHOD  Force install method: inkernel|lwfinger|kali-dkms|ac3rn|aircrack-ng
                         (kali-dkms is refused on kernels > 6.13)
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
  --test                 Run comprehensive test suite after install (implies --skip-verify)
  --remove-mok           Also delete MOK keys on --uninstall (UEFI enrollment remains regardless)
  --help, -h             Show this help

Examples:
  sudo $0                          # Auto-detect and install
  sudo $0 --dry-run                # Preview actions
  sudo $0 --force-method ac3rn     # Force Ac3rN patched DKMS (6.15-6.18)
  sudo $0 --force-method lwfinger  # Force lwfinger/rtw88 managed backport
  sudo $0 --force-method inkernel  # Force in-kernel rtw88 (recommended on 6.19+/7.x)
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
            --force-method) [[ $# -lt 2 ]] && { error "--force-method requires an argument (inkernel|lwfinger|kali-dkms|ac3rn|aircrack-ng)"; usage; exit 1; }; FORCE_METHOD="$2"; shift ;;
            --skip-verify) SKIP_VERIFY=true ;;
            --skip-monitor) SKIP_MONITOR_SETUP=true ;;
            --reg-domain) [[ $# -lt 2 ]] && { error "--reg-domain requires an argument (e.g. BO, US)"; usage; exit 1; }; REG_DOMAIN="$2"; shift ;;
            --performance) ENABLE_PERFORMANCE=true ;;
            --skip-firmware) SKIP_FIRMWARE_UPDATE=true ;;
            --secure-boot) ENABLE_SECURE_BOOT=true ;;
            --pi-optimizations) ENABLE_PI_OPTIMIZATIONS=true ;;
            --watchdog) ENABLE_WATCHDOG=true ;;
            --thermal) ENABLE_THERMAL=true ;;
            --coex) ENABLE_COEX=true ;;
            --skip-crash-collector) SKIP_CRASH_COLLECTOR=true ;;
            --test) RUN_TEST_SUITE=true; SKIP_VERIFY=true ;;
            --remove-mok) REMOVE_MOK_KEYS=true ;;
            --help|-h) usage; exit 0 ;;
            *) error "Unknown option: $1"; usage; exit 1 ;;
        esac
        shift
    done
}

main() {
    parse_args "$@"

    # Root check FIRST: a non-root user must get the friendly error, not a
    # cryptic set -e failure from the log-file mkdir/touch below.
    require_root

    # Initialize log directory/file (before any log/info/warn call).
    # Gated by run() so --dry-run changes nothing; log helpers skip file
    # appends in DRY_RUN mode so this ordering is always safe.
    run "mkdir -p /var/log"
    run "touch '$LOG_FILE'"
    run "chmod 644 '$LOG_FILE'"

    print_banner

    detect_os
    detect_kernel
    detect_arch
    detect_secure_boot
    detect_kali_version
    detect_driver_conflicts

    # Surface detection results (otherwise these would be unused variables).
    info "Kali version: ${KALI_MAJOR}.${KALI_MINOR} (OS: $OS_ID $OS_VERSION)"
    info "Secure Boot state: $SECURE_BOOT_STATE"
    if [[ "$CONFLICT_DETECTED" == true ]]; then
        warn "Conflicting drivers are currently loaded — the installer will blacklist the unused one; reboot after install."
    else
        verbose "No driver conflict detected"
    fi

    if [[ "$UNINSTALL" == true ]]; then
        uninstall_driver
        exit 0
    fi

    check_prerequisites

    # Secure Boot PRE step (MOK key generation) must run BEFORE the DKMS install.
    setup_secure_boot

    choose_strategy

    # Execute chosen strategy
    case "$STRATEGY" in
        inkernel) install_inkernel ;;
        lwfinger) install_lwfinger ;;
        kali-dkms) install_kali_dkms ;;
        ac3rn) install_ac3rn ;;
        aircrack-ng) install_aircrack_ng ;;
        *) error "Unknown strategy: $STRATEGY"; exit 1 ;;
    esac

    # Secure Boot POST step: sign the freshly built DKMS modules.
    setup_secure_boot_post

    setup_performance_config
    update_firmware
    setup_pi_optimizations
    setup_watchdog
    setup_thermal
    setup_coex
    setup_crash_collector
    setup_monitor_mode
    setup_dkms_autorebuild

    # --test implies SKIP_VERIFY (set in parse_args); belt-and-braces here too.
    if [[ "$RUN_TEST_SUITE" == true ]]; then
        SKIP_VERIFY=true
        info "--test requested: skipping smoke verification in favor of full suite"
    fi
    # Failure here must not abort main under set -e before the banner.
    verify_install || warn "Smoke verification reported issues — installation may be incomplete."

    # Run comprehensive test suite if requested (non-fatal).
    if [[ "$RUN_TEST_SUITE" == true ]]; then
        run_full_test_suite || warn "Test suite reported failures — review output above."
    fi

    log "═══════════════════════════════════════════════════════════"
    success "Installation complete!"

    # Resolve the real interface names — never assume a fixed interface name.
    # airmon-ng may enable monitor mode in place (same name) or rename it.
    local final_iface=""
    local final_mon=""
    for i in /sys/class/net/wlan*; do
        [[ -e "$i" ]] || continue
        final_iface=$(basename "$i")
        break
    done
    if [[ -n "$final_iface" ]]; then
        final_mon=$(detect_monitor_iface "$final_iface")
        info "Interface: $final_iface (monitor: $final_mon)"
    else
        info "Interface: no wlan* interface detected — check the adapter is plugged in"
    fi
    info "Monitor mode: Auto-enabled on plug/boot (airmon-ng may keep the same name)"
    info "5GHz channels: Enabled via regulatory domain $REG_DOMAIN"
    info "Log: $LOG_FILE"
    info ""
    info "Quick test:"
    info "  sudo airmon-ng check kill"
    if [[ -n "$final_iface" ]]; then
        info "  sudo airmon-ng start $final_iface"
        info "  iw dev   # note which interface is in monitor mode"
        info "  sudo airodump-ng $final_mon"
    else
        info "  sudo airmon-ng start <iface>   # e.g. wlan0, adjust to your adapter"
        info "  iw dev   # note which interface is in monitor mode"
        info "  sudo airodump-ng <mon_iface>"
    fi
    log "═══════════════════════════════════════════════════════════"
}

main "$@"