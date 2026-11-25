#!/usr/bin/env bash
set -euo pipefail

# create-vm.sh
# Create + boot a VM from an installer ISO (Ubuntu Desktop/Server or any bootable ISO).
# Optional: attach a prebuilt autoinstall/seed ISO (e.g., NoCloud "cidata") as a 2nd CD-ROM.

RED="\033[0;31m"; GREEN="\033[0;32m"; BLUE="\033[0;34m"; NC="\033[0m"
info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
fail()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=lib/efi.sh
source "$SCRIPT_DIR/lib/efi.sh"

usage() {
  cat <<'EOF'
Usage:
  ./create_vm.sh <path/to/os.iso> <vm_name> [options]
  ./create_vm.sh <vm_name> --base IMAGE [--copy]

Positional args:
  ISO path        Path to a bootable ISO (Ubuntu Desktop/Server, etc.). Omitted with --base.
  VM name         Name for the disk file (images/<vm_name>.qcow2)

Options:
  --disk-gb N         Disk size in GB (default: 32)
  --ram-mb N          RAM in MB (default: 4096)
  --cpus N            vCPU count (default: 4)
  --efi PATH          Path to EFI/UEFI firmware (QEMU_EFI.fd). Overrides default + auto-detection.
                      Default: the firmware shipped with QEMU, else ./efi/QEMU_EFI.fd.
  --autoinstall-iso P Path to a prebuilt autoinstall/seed ISO to attach as 2nd CD-ROM
  --no-accel          Force pure emulation (TCG), even if KVM/HVF is available
  --headless          No GUI window (uses serial console); best for servers
  --ssh-port N        Host port forwarded to guest 22 (default: 2222)
  --base IMAGE        Create the disk from an existing image (a name in images/ or a path)
                      instead of installing from an ISO. Creates the disk and exits.
                      Default: a copy-on-write overlay. Never modify IMAGE afterwards,
                      or every overlay built on it is corrupted.
  --copy              With --base: make an independent full copy instead of an overlay
  --config PATH       YAML config profile to load defaults from (-f also works).
                      Default: ./config/default.yaml if present.
                      CLI flags always override the config file.
  -h, --help          Show this help

What this script does:
  • Detects host OS + CPU architecture (x86_64 vs arm64/aarch64)
  • Chooses the correct QEMU binary (qemu-system-x86_64 or qemu-system-aarch64)
  • Uses KVM (Linux) or HVF (macOS) if available, unless --no-accel is set
  • Creates images/<vm_name>.qcow2 (in the repo) if missing
  • Boots the installer ISO and attaches the optional autoinstall ISO if provided
  • User-mode networking with SSH forward: host localhost:<ssh-port> -> guest 22

Notes:
  • On Apple Silicon (arm64), you generally must use an ARM64 ISO.
  • Attaching an autoinstall ISO does not always guarantee unattended install; some ISOs
    still require adding kernel args in GRUB (e.g., "autoinstall ds=nocloud\\;s=/cdrom/").
EOF
}

# Parse required positional args
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage && exit 0
BASE=""
[[ " $* " == *" --base "* ]] && BASE_MODE=1 || BASE_MODE=0
[[ $# -lt $((2 - BASE_MODE)) ]] && usage && exit 1

ISO=""
[[ "$BASE_MODE" -eq 0 ]] && { ISO="$1"; shift; }
VMNAME="$1"; shift
COPY=0

CONFIG_FILE="$(resolve_config_file "$SCRIPT_DIR/config/default.yaml" "$@")"
CONFIG_SECTION="create_vm"
[[ -n "$CONFIG_FILE" ]] && info "Using config profile: $CONFIG_FILE"

# Defaults (config profile overrides these; CLI flags override the config profile)
DISK_GB="$(cfg_get disk_gb 32)"
RAM_MB="$(cfg_get ram_mb 4096)"
CPUS="$(cfg_get cpus 4)"
AUTOINSTALL_ISO="$(cfg_get autoinstall_iso "")"
EFI_FIRMWARE="$(cfg_get efi "")"
NO_ACCEL="$(cfg_get_bool no_accel 0)"
HEADLESS="$(cfg_get_bool headless 0)"
SSH_PORT="$(cfg_get ssh_port 2222)"

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
    --base) shift; BASE="${1:-}";;
    --copy) COPY=1;;
    --config|-f) shift;; # already resolved above
    -h|--help) usage; exit 0;;
    *) fail "Unknown option: $1 (use --help)";;
  esac
  shift || true
done

VMDIR="$SCRIPT_DIR/images"
DISK="$VMDIR/$VMNAME.qcow2"

if [[ "$BASE_MODE" -eq 1 ]]; then
  [[ -n "$BASE" ]] || fail "--base requires an image name or path"
  [[ ! -f "$BASE" && -f "$VMDIR/$BASE.qcow2" ]] && BASE="$VMDIR/$BASE.qcow2"
  [[ -f "$BASE" ]] || fail "Base image not found: $BASE (also looked for $VMDIR/$BASE.qcow2)"
  [[ -e "$DISK" ]] && fail "Disk already exists: $DISK"
  command -v qemu-img >/dev/null 2>&1 || fail "Missing qemu-img (install qemu-utils / qemu)."
  BASE="$(cd "$(dirname "$BASE")" && pwd)/$(basename "$BASE")"
  mkdir -p "$VMDIR"
  if [[ "$COPY" -eq 1 ]]; then
    info "Copying $BASE -> $DISK"
    qemu-img convert -p -O qcow2 "$BASE" "$DISK"
  else
    # A relative backing path keeps overlays valid when the repo is moved
    BACKING="$BASE"
    [[ "$(dirname "$BASE")" == "$VMDIR" ]] && BACKING="$(basename "$BASE")"
    info "Creating overlay $DISK on $BASE"
    qemu-img create -f qcow2 -F qcow2 -b "$BACKING" "$DISK" >/dev/null
  fi
  ok "Disk created. Start it with: ./start_vm.sh $VMNAME"
  exit 0
fi
[[ "$COPY" -eq 0 ]] || fail "--copy requires --base"

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

  # Prefer -cpu host when we have hardware accel; otherwise choose a safe emulated CPU.
  if [[ "${ACCEL_ARGS[*]}" =~ (kvm|hvf) ]]; then
    CPU_ARGS=(-cpu host)
  else
    CPU_ARGS=(-cpu qemu64)
  fi
else
  MACHINE_ARGS=(-machine virt)

  # Prefer -cpu host when we have hardware accel; otherwise choose a safe emulated CPU.
  if [[ "${ACCEL_ARGS[*]}" =~ (kvm|hvf) ]]; then
    CPU_ARGS=(-cpu host)
  else
    CPU_ARGS=(-cpu cortex-a57)
  fi

  # -bios loads firmware of any size; pflash would require a 64 MB image
  [[ -n "$EFI_FIRMWARE" ]] || EFI_FIRMWARE="$(find_efi_firmware)"
  if [[ -n "$EFI_FIRMWARE" ]]; then
    info "Using EFI firmware: $EFI_FIRMWARE"
    UEFI_ARGS=(-bios "$EFI_FIRMWARE")
  else
    info "No EFI firmware found. Some ARM64 ISOs may not boot."
    info "Tip: install QEMU's EDK2 firmware or pass --efi <path>"
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