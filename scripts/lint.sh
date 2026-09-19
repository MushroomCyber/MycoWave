#!/usr/bin/env bash
# =============================================================================
# MycoWave - Local Lint Runner
# Discovers every shell file, runs `bash -n` on all of them and, when
# shellcheck is available, runs static analysis at a configurable severity.
# Dev tool only - it is NOT installed to /usr/local/bin.
# =============================================================================

set -euo pipefail

# ─── Configuration ──────────────────────────────────────────────────────────
# Minimum shellcheck severity: error, warning, info or style (default: warning)
SHELLCHECK_SEVERITY="${SHELLCHECK_SEVERITY:-warning}"

# Resolve repo root from this script's location so it works from any CWD
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Colors (repo style)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()     { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $*"; }
info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }

# ─── Discovery ──────────────────────────────────────────────────────────────
# Every *.sh in the repo root and scripts/, the extensionless NetworkManager
# dispatcher, and any other file whose first line is a bash/sh shebang.
discover_shell_files() {
    {
        find . -path ./.git -prune -o -type f -name '*.sh' -print
        if [[ -f scripts/99-mycowave-wifi-recover ]]; then
            printf '%s\n' scripts/99-mycowave-wifi-recover
        fi
        grep -rIl -m1 -E '^#!.*\b(bash|sh)\b' --exclude-dir=.git . 2>/dev/null || true
    } | sed 's|^\./||' | sort -u
}

# ─── Main ───────────────────────────────────────────────────────────────────
failed=0
bash_failed=0
shellcheck_failed=0

mapfile -t SHELL_FILES < <(discover_shell_files)

log "MycoWave lint runner (repo: $REPO_ROOT)"
info "Discovered ${#SHELL_FILES[@]} shell file(s)"

if [[ "${#SHELL_FILES[@]}" -eq 0 ]]; then
    error "No shell files found - check the discovery logic"
    exit 1
fi

echo
log "Step 1/2: syntax check (bash -n)"
for f in "${SHELL_FILES[@]}"; do
    if bash -n "$f"; then
        success "bash -n: $f"
    else
        error "bash -n FAILED: $f"
        bash_failed=1
        failed=1
    fi
done

echo
log "Step 2/2: static analysis (shellcheck --severity=${SHELLCHECK_SEVERITY})"
if command -v shellcheck >/dev/null 2>&1; then
    for f in "${SHELL_FILES[@]}"; do
        if shellcheck --severity="${SHELLCHECK_SEVERITY}" "$f"; then
            success "shellcheck: $f"
        else
            error "shellcheck FAILED: $f"
            shellcheck_failed=1
            failed=1
        fi
    done
else
    warn "shellcheck not found on PATH - skipping static analysis"
    warn "Install it to enable this step, e.g.: apt-get install shellcheck"
fi

echo
log "========== Lint summary =========="
info "Shell files checked: ${#SHELL_FILES[@]}"
if [[ "$bash_failed" -eq 0 ]]; then
    success "bash -n: PASS"
else
    error "bash -n: FAIL"
fi
if command -v shellcheck >/dev/null 2>&1; then
    if [[ "$shellcheck_failed" -eq 0 ]]; then
        success "shellcheck: PASS"
    else
        error "shellcheck: FAIL"
    fi
else
    warn "shellcheck: SKIPPED (not installed)"
fi
log "=================================="

if [[ "$failed" -ne 0 ]]; then
    error "Lint checks failed"
    exit 1
fi

success "All lint checks passed"
