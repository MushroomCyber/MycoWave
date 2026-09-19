#!/usr/bin/env bash
# =============================================================================
# MycoWave - Secure Boot MOK Enrollment Automation
# Generates MOK key, enrolls in UEFI, signs DKMS modules
# =============================================================================

set -euo pipefail

# ─── Configuration ──────────────────────────────────────────────────────────
MOK_DIR="/var/lib/shim-signed/mok"
MOK_KEY="${MOK_DIR}/MOK.priv"
MOK_CERT="${MOK_DIR}/MOK.der"
MOK_PW_TEMP=""

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

# ─── Helper Functions ────────────────────────────────────────────────────────
require_root() {
    [[ $EUID -eq 0 ]] || { error "Run as root (sudo)"; exit 1; }
}

check_secure_boot() {
    if command -v mokutil >/dev/null 2>&1; then
        local sb_state=$(mokutil --sb-state 2>/dev/null || echo "unknown")
        if echo "$sb_state" | grep -qi "enabled"; then
            SECURE_BOOT="enabled"
            info "Secure Boot: ENABLED"
            return 0
        else
            SECURE_BOOT="disabled"
            warn "Secure Boot: DISABLED (MOK enrollment not required)"
            return 1
        fi
    else
        warn "mokutil not installed - cannot detect Secure Boot state"
        SECURE_BOOT="unknown"
        return 1
    fi
}

# ─── Main Functions ──────────────────────────────────────────────────────────
generate_mok_key() {
    log "Generating MOK key pair..."

    mkdir -p "$MOK_DIR"
    chmod 700 "$MOK_DIR"

    if [[ -f "$MOK_KEY" && -f "$MOK_CERT" ]]; then
        info "MOK key already exists at $MOK_KEY"
        return 0
    fi

    # Generate 10-year certificate
    openssl req -new -x509 -newkey rsa:2048 \
        -keyout "$MOK_KEY" \
        -outform DER -out "$MOK_CERT" \
        -nodes -days 36500 \
        -subj "/CN=MycoWave DKMS Module Signing/"

    chmod 600 "$MOK_KEY"
    chmod 644 "$MOK_CERT"

    success "MOK key generated:"
    info "  Private key: $MOK_KEY"
    info "  Certificate: $MOK_CERT"
}

enroll_mok() {
    log "Enrolling MOK in UEFI..."

    if ! check_secure_boot; then
        warn "Secure Boot not enabled - skipping MOK enrollment"
        return 0
    fi

    # Check if already enrolled
    if mokutil --test-key "$MOK_CERT" 2>/dev/null | grep -q "is enrolled"; then
        info "MOK already enrolled in UEFI"
        return 0
    fi

    # Generate one-time password for MOK enrollment.
    # Held only in a root-only temp file (removed on exit), never persisted.
    MOK_PW_TEMP=$(mktemp)
    chmod 600 "$MOK_PW_TEMP"
    trap 'rm -f "${MOK_PW_TEMP:-}"' EXIT
    openssl rand -base64 12 | tr -d '=+/' > "$MOK_PW_TEMP"
    local mok_password
    mok_password=$(cat "$MOK_PW_TEMP")

    echo ""
    echo "MOK enrollment password: $mok_password"
    echo "SAVE THIS PASSWORD - you'll need it on next reboot!"
    echo ""

    # Enroll with password via pipe
    echo -e "$mok_password\n$mok_password" | mokutil --import "$MOK_CERT"

    # Disable timeout (requires reboot to take effect)
    mokutil --timeout -1 2>/dev/null || true

    success "MOK enrollment initiated"
    warn "=============================================="
    warn "REBOOT REQUIRED"
    warn "On reboot, you'll see a blue 'MOK Manager' screen:"
    warn "  1. Select 'Enroll MOK'"
    warn "  2. Select 'Continue'"
    warn "  3. Select 'Yes' to enroll"
    warn "  4. Enter the password you saved above"
    warn "  5. Select 'Reboot'"
    warn "=============================================="
}

sign_dkms_modules() {
    log "Signing DKMS modules for current kernel..."

    local kernel_ver=$(uname -r)
    local sign_tool=""

    # Find sign-file script
    if [[ -x "/lib/modules/${kernel_ver}/build/scripts/sign-file" ]]; then
        sign_tool="/lib/modules/${kernel_ver}/build/scripts/sign-file"
    elif [[ -x "/usr/src/linux-headers-${kernel_ver}/scripts/sign-file" ]]; then
        sign_tool="/usr/src/linux-headers-${kernel_ver}/scripts/sign-file"
    elif command -v kmodsign >/dev/null 2>&1; then
        sign_tool="kmodsign"
    else
        error "sign-file or kmodsign not found. Install linux-headers-$(uname -r)"
        return 1
    fi

    info "Using signing tool: $sign_tool"

    # Sign all installed DKMS modules
    local signed=0
    while IFS= read -r line; do
        # Parse: "modulename, version, kernelver, arch: status"
        local name=$(echo "$line" | cut -d',' -f1 | xargs)
        local version=$(echo "$line" | cut -d',' -f2 | xargs)
        local kern=$(echo "$line" | cut -d',' -f3 | xargs)
        local arch=$(echo "$line" | cut -d',' -f4 | cut -d':' -f1 | xargs)

        if [[ "$kern" != "$kernel_ver" ]]; then
            continue
        fi

        local mod_dir="/var/lib/dkms/${name}/${version}/${kern}/${arch}/module"
        if [[ -d "$mod_dir" ]]; then
            for ko in "$mod_dir"/*.ko*; do
                [[ -f "$ko" ]] || continue
                log "Signing: $ko"
                if "$sign_tool" sha256 "$MOK_KEY" "$MOK_CERT" "$ko" 2>/dev/null; then
                    signed=$((signed + 1))
                fi
            done
        fi
    done < <(dkms status --installed 2>/dev/null)

    success "Signed $signed module(s) for kernel $kernel_ver"
}

verify_enrollment() {
    log "Verifying MOK enrollment..."

    if ! check_secure_boot; then
        return 0
    fi

    if mokutil --test-key "$MOK_CERT" 2>/dev/null | grep -q "is enrolled"; then
        success "MOK is enrolled and active"
        return 0
    else
        warn "MOK not yet enrolled (reboot may be needed)"
        return 1
    fi
}

show_status() {
    log "MOK Status:"
    echo "  Secure Boot: ${SECURE_BOOT:-unknown}"
    echo "  MOK Directory: $MOK_DIR"
    echo "  Private Key: $MOK_KEY $([ -f "$MOK_KEY" ] && echo "✓" || echo "✗")"
    echo "  Certificate: $MOK_CERT $([ -f "$MOK_CERT" ] && echo "✓" || echo "✗")"

    if [[ "$SECURE_BOOT" == "enabled" ]]; then
        if mokutil --test-key "$MOK_CERT" 2>/dev/null | grep -q "is enrolled"; then
            echo "  Enrollment: ✓ Enrolled"
        else
            echo "  Enrollment: ✗ Not enrolled"
        fi
    fi

    # Show enrolled keys
    echo ""
    log "Currently enrolled keys:"
    mokutil --list-enrolled 2>/dev/null | head -20 || echo "  (none or mokutil error)"
}

# ─── CLI ─────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: sudo $0 [COMMAND]

Commands:
  generate       Generate MOK key pair
  enroll         Enroll MOK in UEFI (requires reboot)
  sign           Sign all DKMS modules for current kernel
  verify         Verify MOK enrollment status
  status         Show MOK status
  full           Run generate + enroll + sign (complete setup)
  help           Show this help

Examples:
  sudo $0 full              # Complete setup (recommended)
  sudo $0 generate          # Just generate key
  sudo $0 enroll            # Enroll existing key
  sudo $0 sign              # Sign modules after kernel update
  sudo $0 status            # Check status
EOF
}

main() {
    local cmd="${1:-full}"

    case "$cmd" in
        generate)
            require_root
            generate_mok_key
            ;;
        enroll)
            require_root
            generate_mok_key
            enroll_mok
            ;;
        sign)
            require_root
            sign_dkms_modules
            ;;
        verify)
            require_root
            verify_enrollment
            ;;
        status)
            require_root
            check_secure_boot || true
            show_status
            ;;
        full)
            require_root
            generate_mok_key
            enroll_mok
            sign_dkms_modules
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