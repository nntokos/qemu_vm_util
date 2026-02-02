#!/usr/bin/env bash
set -euo pipefail

# create-vm.sh
# Create + boot a VM from an installer ISO (Ubuntu Desktop/Server or any bootable ISO).
# Optional: attach a prebuilt autoinstall/seed ISO (e.g., NoCloud "cidata") as a 2nd CD-ROM.

RED="\033[0;31m"; GREEN="\033[0;32m"; BLUE="\033[0;34m"; NC="\033[0m"
info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
fail()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  ./create-vm.sh <path/to/os.iso> <vm_name> [options]

Required positional args:
  1) ISO path     Path to a bootable ISO (Ubuntu Desktop/Server, etc.)
  2) VM name      Name for the VM directory + disk file

Options:
  --disk-gb N         Disk size in GB (default: 32)
  --ram-mb N          RAM in MB (default: 4096)
  --cpus N            vCPU count (default: 4)
  --efi PATH          Path to EFI/UEFI firmware (QEMU_EFI.fd). Overrides default + auto-detection.
                      Default behavior: use ./efi/QEMU_EFI.fd if present, otherwise auto-detect.
  --autoinstall-iso P Path to a prebuilt autoinstall/seed ISO to attach as 2nd CD-ROM
  --no-accel          Force pure emulation (TCG), even if KVM/HVF is available
  --headless          No GUI window (uses serial console); best for servers
  --ssh-port N        Host port forwarded to guest 22 (default: 2222)
  -h, --help          Show this help

What this script does:
  • Detects host OS + CPU architecture (x86_64 vs arm64/aarch64)
  • Chooses the correct QEMU binary (qemu-system-x86_64 or qemu-system-aarch64)
  • Uses KVM (Linux) or HVF (macOS) if available, unless --no-accel is set
  • Creates ./<vm_name>/<vm_name>.qcow2 if missing
  • Boots the installer ISO and attaches the optional autoinstall ISO if provided
  • User-mode networking with SSH forward: host localhost:<ssh-port> -> guest 22

Notes:
  • On Apple Silicon (arm64), you generally must use an ARM64 ISO.
  • Attaching an autoinstall ISO does not always guarantee unattended install; some ISOs
    still require adding kernel args in GRUB (e.g., "autoinstall ds=nocloud\\;s=/cdrom/").
EOF
}

# Defaults
DISK_GB=32
RAM_MB=4096
CPUS=4
AUTOINSTALL_ISO=""
EFI_FIRMWARE=""
REPO_EFI="./efi/QEMU_EFI.fd"
NO_ACCEL=0
HEADLESS=0
SSH_PORT=2222

# Parse required positional args
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage && exit 0
[[ $# -lt 2 ]] && usage && exit 1

ISO="$1"; shift
VMNAME="$1"; shift

# Parse named options
while [[ $# -gt 0 ]]; do
  case "$1" in
    --disk-gb) shift; DISK_GB="${1:-}";;
    --ram-mb) shift; RAM_MB="${1:-}";;
    --cpus) shift; CPUS="${1:-}";;
    --autoinstall-iso) shift; AUTOINSTALL_ISO="${1:-}";;
    --efi) shift; EFI_FIRMWARE="${1:-}";;
    --no-accel) NO_ACCEL=1;;
    --headless) HEADLESS=1;;
    --ssh-port) shift; SSH_PORT="${1:-}";;
    -h|--help) usage; exit 0;;
    *) fail "Unknown option: $1 (use --help)";;
  esac
  shift || true
done

[[ -f "$ISO" ]] || fail "ISO not found: $ISO"
[[ "$DISK_GB" =~ ^[0-9]+$ ]] || fail "--disk-gb must be an integer"
[[ "$RAM_MB" =~ ^[0-9]+$ ]] || fail "--ram-mb must be an integer"
[[ "$CPUS" =~ ^[0-9]+$ ]] || fail "--cpus must be an integer"
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] || fail "--ssh-port must be an integer"
[[ -z "$AUTOINSTALL_ISO" || -f "$AUTOINSTALL_ISO" ]] || fail "autoinstall ISO not found: $AUTOINSTALL_ISO"
[[ -z "$EFI_FIRMWARE" || -f "$EFI_FIRMWARE" ]] || fail "EFI firmware not found: $EFI_FIRMWARE"

OS="$(uname -s)"
ARCH="$(uname -m)"

case "$ARCH" in
  x86_64|amd64) HOST_ARCH="x86_64" ;;
  arm64|aarch64) HOST_ARCH="aarch64" ;;
  *) fail "Unsupported CPU architecture: $ARCH" ;;
esac

info "Host OS: $OS"
info "Host arch: $HOST_ARCH"

# Choose QEMU binary
if [[ "$HOST_ARCH" == "x86_64" ]]; then
  QEMU_BIN="qemu-system-x86_64"
else
  QEMU_BIN="qemu-system-aarch64"
fi

command -v "$QEMU_BIN" >/dev/null 2>&1 || {
  if [[ "$OS" == "Darwin" ]]; then
    fail "Missing $QEMU_BIN. Install with: brew install qemu"
  elif [[ "$OS" == "Linux" ]]; then
    fail "Missing $QEMU_BIN. Install QEMU (e.g. apt install qemu-system-x86 or qemu-system-aarch64)"
  else
    fail "Missing $QEMU_BIN."
  fi
}

command -v qemu-img >/dev/null 2>&1 || fail "Missing qemu-img (install qemu-utils / qemu)."

# Acceleration detection
ACCEL_ARGS=()
if [[ "$NO_ACCEL" -eq 1 ]]; then
  ACCEL_ARGS=(-accel tcg)
  info "Acceleration disabled via --no-accel (using TCG)"
else
  if [[ "$OS" == "Linux" ]]; then
    if [[ -e /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
      ACCEL_ARGS=(-accel kvm)
      ok "Using KVM acceleration"
    else
      ACCEL_ARGS=(-accel tcg)
      info "KVM not available; using TCG (emulation)"
    fi
  elif [[ "$OS" == "Darwin" ]]; then
    ACCEL_ARGS=(-accel hvf)
    ok "Using HVF acceleration (best effort)"
  else
    ACCEL_ARGS=(-accel tcg)
    info "Unknown OS accel; using TCG"
  fi
fi

# VM paths
VMDIR="./images"
DISK="$VMDIR/$VMNAME.qcow2"
mkdir -p "$VMDIR"

if [[ ! -f "$DISK" ]]; then
  info "Creating disk: $DISK (${DISK_GB}G)"
  qemu-img create -f qcow2 "$DISK" "${DISK_GB}G" >/dev/null
  ok "Disk created"
else
  info "Disk already exists: $DISK (will reuse)"
fi

# Common devices
NET_ARGS=(-netdev user,id=n1,hostfwd=tcp::${SSH_PORT}-:22 -device virtio-net-pci,netdev=n1)
DRIVE_ARGS=(-drive file="$DISK",if=virtio,format=qcow2)
CDROM_ARGS=(-cdrom "$ISO" -boot d)

# Optional autoinstall ISO attached as a second CD-ROM
SEED_ARGS=()
if [[ -n "$AUTOINSTALL_ISO" ]]; then
  info "Attaching autoinstall/seed ISO: $AUTOINSTALL_ISO"
  SEED_ARGS=(-drive file="$AUTOINSTALL_ISO",media=cdrom,readonly=on)
fi

# Display / console
if [[ "$HEADLESS" -eq 1 ]]; then
  DISPLAY_ARGS=(-nographic)
  info "Headless mode enabled (--headless)"
else
  DISPLAY_ARGS=(-display default)
fi

# Machine-specific args
MACHINE_ARGS=()
CPU_ARGS=()
UEFI_ARGS=()

if [[ "$HOST_ARCH" == "x86_64" ]]; then
  MACHINE_ARGS=(-machine q35)
  CPU_ARGS=(-cpu host)
else
  MACHINE_ARGS=(-machine virt)

  # Prefer -cpu host when we have hardware accel; otherwise choose a safe emulated CPU.
  if [[ "${ACCEL_ARGS[*]}" =~ (kvm|hvf) ]]; then
    CPU_ARGS=(-cpu host)
  else
    CPU_ARGS=(-cpu cortex-a57)
  fi

  # EFI / UEFI firmware handling (AArch64):
  # Priority:
  #   1) --efi PATH
  #   2) ./efi/QEMU_EFI.fd (repo default)
  #   3) auto-detect common system locations
  if [[ -n "$EFI_FIRMWARE" ]]; then
    info "Using user-specified EFI firmware: $EFI_FIRMWARE"
    UEFI_ARGS=(-drive if=pflash,format=raw,readonly=on,file="$EFI_FIRMWARE")

  elif [[ -f "$REPO_EFI" ]]; then
    info "Using repo EFI firmware: $REPO_EFI"
    UEFI_ARGS=(-drive if=pflash,format=raw,readonly=on,file="$REPO_EFI")

  else
    for fw in \
      /usr/share/qemu-efi-aarch64/QEMU_EFI.fd \
      /usr/share/edk2/aarch64/QEMU_EFI.fd \
      /opt/homebrew/share/qemu/edk2-aarch64-code.fd \
      /usr/local/share/qemu/edk2-aarch64-code.fd
    do
      if [[ -f "$fw" ]]; then
        info "Using auto-detected EFI firmware: $fw"
        UEFI_ARGS=(-drive if=pflash,format=raw,readonly=on,file="$fw")
        break
      fi
    done

    if [[ ${#UEFI_ARGS[@]} -eq 0 ]]; then
      info "No EFI firmware found. Some ARM64 ISOs may not boot."
      info "Tip: place firmware at ./efi/QEMU_EFI.fd or pass --efi <path>"
    fi
  fi
fi

info "VM directory: $VMDIR"
info "SSH after install (if enabled in guest): ssh -p ${SSH_PORT} <user>@localhost"
info "Launching installer..."

set -x
"$QEMU_BIN" \
  "${ACCEL_ARGS[@]}" \
  "${MACHINE_ARGS[@]}" \
  "${CPU_ARGS[@]}" \
  -m "$RAM_MB" \
  -smp "$CPUS" \
  "${UEFI_ARGS[@]}" \
  "${DRIVE_ARGS[@]}" \
  "${CDROM_ARGS[@]}" \
  "${SEED_ARGS[@]}" \
  "${NET_ARGS[@]}" \
  -device virtio-rng-pci \
  "${DISPLAY_ARGS[@]}"