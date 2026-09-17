# MycoWave - Secure Boot / MOK Enrollment Guide

## Overview

Secure Boot prevents unsigned kernel modules from loading. DKMS drivers (88XXau, 8812au) must be signed with a Machine Owner Key (MOK) enrolled in UEFI.

MycoWave's `--secure-boot` flag automates this process.

---

## Quick Start

```bash
# During install
sudo ./mycowave-install.sh --secure-boot

# Or standalone
sudo /usr/local/bin/mycowave-enroll-mok full
```

---

## What Happens

### 1. MOK Key Generation
Creates RSA-2048 key pair in `/var/lib/shim-signed/mok/`:
- `MOK.priv` — Private key (used for signing)
- `MOK.der` — Public certificate (enrolled in UEFI)

### 2. MOK Enrollment
Runs `mokutil --import MOK.der` with a one-time password.

### 3. Reboot Required
On next boot, blue **MOK Manager** screen appears:
```
┌─────────────────────────────────────┐
│  Shim UEFI Key Management           │
├─────────────────────────────────────┤
│  Enroll MOK                         │
│  Enroll key from disk               │
│  Enroll hash from disk              │
│  Continue                           │
└─────────────────────────────────────┘
```

**Steps**:
1. Select **Enroll MOK** → **Continue** → **Yes**
2. Enter the one-time password shown during enrollment
3. Select **Reboot**

### 4. Module Signing
All DKMS modules for current kernel are signed with the MOK key.

---

## Manual Process

### Generate Key
```bash
sudo mkdir -p /var/lib/shim-signed/mok
sudo chmod 700 /var/lib/shim-signed/mok

sudo openssl req -new -x509 -newkey rsa:2048 \
    -keyout /var/lib/shim-signed/mok/MOK.priv \
    -outform DER -out /var/lib/shim-signed/mok/MOK.der \
    -nodes -days 36500 \
    -subj "/CN=MycoWave DKMS Module Signing/"

sudo chmod 600 /var/lib/shim-signed/mok/MOK.priv
sudo chmod 644 /var/lib/shim-signed/mok/MOK.der
```

### Enroll in UEFI
```bash
sudo mokutil --import /var/lib/shim-signed/mok/MOK.der
# Enter password when prompted (twice)
sudo mokutil --timeout -1  # Disable timeout
```

### Reboot & Complete
Reboot and follow MOK Manager prompts.

### Sign Modules
```bash
# Find sign-file
SIGN_TOOL="/usr/src/linux-headers-$(uname -r)/scripts/sign-file"

# Sign all DKMS modules
dkms status --installed | while read line; do
    name=$(echo "$line" | cut -d',' -f1)
    version=$(echo "$line" | cut -d',' -f2)
    kern=$(echo "$line" | cut -d',' -f3)
    arch=$(echo "$line" | cut -d',' -f4 | cut -d':' -f1)

    if [[ "$kern" == "$(uname -r)" ]]; then
        for ko in /var/lib/dkms/$name/$version/$kern/$arch/module/*.ko; do
            $SIGN_TOOL sha256 \
                /var/lib/shim-signed/mok/MOK.priv \
                /var/lib/shim-signed/mok/MOK.der \
                "$ko"
        done
    fi
done
```

---

## Verification

```bash
# Check Secure Boot state
mokutil --sb-state

# Check if MOK is enrolled
mokutil --test-key /var/lib/shim-signed/mok/MOK.der

# List all enrolled keys
mokutil --list-enrolled

# Check module signatures
for mod in 88XXau 8812au 8814au; do
    if lsmod | grep -q "^$mod"; then
        modinfo $mod | grep -i sign
    fi
done
```

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "Required key not available" | MOK not enrolled or module not signed |
| MOK Manager doesn't appear | Check Secure Boot enabled in BIOS/UEFI |
| Password rejected | Password is case-sensitive; re-enroll with new key |
| "mokutil: command not found" | `apt install mokutil` |
| "sign-file not found" | `apt install linux-headers-$(uname -r)` |
| Modules still won't load | Rebuild DKMS: `dkms autoinstall -k $(uname -r)` |

---

## After Kernel Update

When kernel updates, DKMS rebuilds modules but they're **unsigned**.

Options:
1. **Re-run enrollment script**: `sudo /usr/local/bin/mycowave-enroll-mok sign`
2. **Auto-sign via DKMS**: Add to `/usr/src/<module>-<ver>/dkms.conf`:
   ```bash
   POST_BUILD="$(dirname $0)/scripts/sign-file sha256 /var/lib/shim-signed/mok/MOK.priv /var/lib/shim-signed/mok/MOK.der $MODULE_FILE"
   ```

---

## Disabling Secure Boot (Alternative)

If MOK enrollment is not feasible:

1. Enter BIOS/UEFI (usually F2, F12, Del on boot)
2. Navigate to Security → Secure Boot
3. Set to **Disabled**
4. Save and exit

Then install without `--secure-boot`:
```bash
sudo ./mycowave-install.sh
```

---

## Script Reference

`/usr/local/bin/mycowave-enroll-mok` commands:

| Command | Description |
|---------|-------------|
| `generate` | Generate MOK key pair only |
| `enroll` | Enroll existing key in UEFI |
| `sign` | Sign all DKMS modules for current kernel |
| `verify` | Verify MOK enrollment status |
| `status` | Show MOK status |
| `full` | Generate + enroll + sign (complete setup) |