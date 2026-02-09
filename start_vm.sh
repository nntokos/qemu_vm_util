#!/usr/bin/env bash
#
# start_vm.sh - Boot a VM from an existing disk image (no cloning)
#
# Usage:
#   ./start_vm.sh <image.qcow2> [options]
#
# Positional:
#   image.qcow2          Path to an existing qcow2 disk image to boot (required)
#
# Options:
#   -n, --name NAME      Name for the VM (default: test-$(timestamp))
#   -m, --memory MB      Memory in MB (default: 4096)
#   -c, --cpus N         Number of CPU cores (default: 2)
#   -p, --ssh-port PORT  SSH port forwarding (default: 2222)
#   -d, --shared-dir DIR Directory to mount in VM (can be specified multiple times)
#       --efi PATH       Path to EFI/UEFI firmware (QEMU_EFI.fd).
#                        Default: ./efi/QEMU_EFI.fd (relative to script directory)
#   -h, --help           Show this help message
#
# Example:
#   ./start_vm.sh images/ubuntu-cse3320/ubuntu-example.qcow2
#   ./start_vm.sh images/ubuntu-cse3320/ubuntu-example.qcow2 -n mytest -m 8192
#   ./start_vm.sh images/ubuntu-cse3320/ubuntu-example.qcow2 --efi ./efi/QEMU_EFI.fd
#   ./start_vm.sh images/ubuntu-cse3320/ubuntu-example.qcow2 -d ~/myfiles -d ~/projects

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────

# EFI default (repo-relative)
REPO_EFI_DEFAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/efi/QEMU_EFI.fd"

# Defaults
VM_NAME="test-$(date +%Y%m%d-%H%M%S)"
MEMORY=4096
CPUS=2
SSH_PORT=2222
SHARED_DIRS=()

# Optional override; defaults to repo EFI
UEFI_FIRMWARE="$REPO_EFI_DEFAULT"

# ─────────────────────────────────────────────────────────────────────────────
# Helper functions
# ─────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info()  { printf "${BLUE}[INFO]${NC} %s\n" "$*"; }
log_ok()    { printf "${GREEN}[OK]${NC} %s\n" "$*"; }
log_warn()  { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
log_error() { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }

print_command() {
    local cmd=$1
    shift
    printf "  %q" "$cmd"
    for arg in "$@"; do
        printf " %q" "$arg"
    done
    printf "\n"
}

usage() {
    sed -n '3,/^$/p' "$0" | sed 's/^# //' | sed 's/^#//'
    exit 0
}

detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) echo "x86_64" ;;
        arm64|aarch64) echo "arm64" ;;
        *) log_error "Unsupported architecture: $arch"; exit 1 ;;
    esac
}

detect_os() {
    case "$(uname -s)" in
        Linux) echo "linux" ;;
        Darwin) echo "macos" ;;
        *) log_error "Unsupported OS: $(uname -s)"; exit 1 ;;
    esac
}

check_dependencies() {
    local arch os
    arch=$(detect_arch)
    os=$(detect_os)

    # Check QEMU
    if [[ "$arch" == "x86_64" ]]; then
        if ! command -v qemu-system-x86_64 &>/dev/null; then
            log_error "qemu-system-x86_64 not found. Install QEMU first."
            [[ "$os" == "linux" ]] && echo "  sudo apt install qemu-kvm qemu-utils"
            [[ "$os" == "macos" ]] && echo "  brew install qemu"
            exit 1
        fi
    else
        if ! command -v qemu-system-aarch64 &>/dev/null; then
            log_error "qemu-system-aarch64 not found. Install QEMU first."
            [[ "$os" == "linux" ]] && echo "  sudo apt install qemu-system-aarch64 qemu-utils"
            [[ "$os" == "macos" ]] && echo "  brew install qemu"
            exit 1
        fi
    fi

    # Check UEFI firmware for ARM (repo-first default, user-overridable via --efi)
    if [[ "$arch" == "arm64" ]]; then
        if [[ ! -f "$UEFI_FIRMWARE" ]]; then
            log_error "UEFI firmware not found: $UEFI_FIRMWARE"
            log_error "Provide it via --efi <path> or place it at: $REPO_EFI_DEFAULT"
            exit 1
        fi
    fi
}

validate_memory() {
    local mem=$1
    # Check if it's a valid positive integer
    if ! [[ "$mem" =~ ^[0-9]+$ ]]; then
        log_error "Memory must be a positive integer (MB), got: $mem"
        exit 1
    fi
    # Check reasonable bounds (8MB - 1TB)
    if ((mem < 8)); then
        log_error "Memory too small: ${mem}MB (minimum: 8MB)"
        exit 1
    fi
    if ((mem > 1048576)); then
        log_error "Memory too large: ${mem}MB (maximum: 1048576MB / 1TB)"
        exit 1
    fi
}

validate_cpus() {
    local cpus=$1
    # Check if it's a valid positive integer
    if ! [[ "$cpus" =~ ^[0-9]+$ ]]; then
        log_error "CPUs must be a positive integer, got: $cpus"
        exit 1
    fi
    # Check reasonable bounds (1 - 256)
    if ((cpus < 1)); then
        log_error "CPUs must be at least 1, got: $cpus"
        exit 1
    fi
    if ((cpus > 256)); then
        log_error "CPUs too many: $cpus (maximum: 256)"
        exit 1
    fi
}

validate_shared_dirs() {
    local failed=0
    for dir in "${SHARED_DIRS[@]}"; do
        if [[ ! -d "$dir" ]]; then
            log_error "Shared directory does not exist: $dir"
            ((failed++))
        fi
    done
    if ((failed > 0)); then
        exit 1
    fi
}

validate_ssh_port() {
    local port=$1
    # Check if it's a valid positive integer
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        log_error "SSH port must be a positive integer, got: $port"
        exit 1
    fi
    # Check valid port range (1-65535)
    if ((port < 1 || port > 65535)); then
        log_error "SSH port out of range: $port (valid range: 1-65535)"
        exit 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Parse arguments (positional image first; options after)
# ─────────────────────────────────────────────────────────────────────────────

# Check for help flag early, before validating required arguments
for arg in "$@"; do
    if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
        usage
    fi
done

if [[ $# -lt 1 ]]; then
    log_error "Missing required positional argument: <image.qcow2>"
    echo ""
    usage
fi

IMAGE_PATH="$1"
shift

while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--name)
            VM_NAME="$2"
            shift 2
            ;;
        -m|--memory)
            MEMORY="$2"
            shift 2
            ;;
        -c|--cpus)
            CPUS="$2"
            shift 2
            ;;
        -p|--ssh-port)
            SSH_PORT="$2"
            shift 2
            ;;
        -d|--shared-dir)
            SHARED_DIRS+=("$2")
            shift 2
            ;;
        --efi)
            UEFI_FIRMWARE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
done

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

main() {
    local arch os
    arch=$(detect_arch)
    os=$(detect_os)

    log_info "Detecting system: $os / $arch"
    check_dependencies

    # Validate input parameters
    log_info "Validating input parameters..."
    validate_memory "$MEMORY"
    validate_cpus "$CPUS"
    validate_ssh_port "$SSH_PORT"
    if [[ ${#SHARED_DIRS[@]} -gt 0 ]]; then
        validate_shared_dirs
    fi

    if [[ ! -f "$IMAGE_PATH" ]]; then
        log_error "Image not found: $IMAGE_PATH"
        exit 1
    fi

    # Show configuration and prompt for confirmation
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "  Start VM From Existing Disk"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    printf "  ${CYAN}VM Configuration:${NC}\n"
    echo "    Name:           $VM_NAME"
    echo "    Memory:         ${MEMORY}MB"
    echo "    CPUs:           $CPUS"
    echo "    SSH Port:       $SSH_PORT"
    echo ""
    printf "  ${CYAN}Paths:${NC}\n"
    echo "    Disk image:     $IMAGE_PATH"
    if [[ ${#SHARED_DIRS[@]} -gt 0 ]]; then
        echo "    Shared dirs:"
        for dir in "${SHARED_DIRS[@]}"; do
            echo "      - $dir"
        done
    fi
    echo ""
    printf "  ${CYAN}System:${NC}\n"
    echo "    Architecture:   $arch"
    echo "    OS:             $os"
    if [[ "$arch" == "arm64" ]]; then
        echo "    UEFI firmware:  $UEFI_FIRMWARE"
    fi
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""

    echo -n "  Start this VM? (Y/n): "
    read -r confirm
    if [[ "${confirm,,}" == "n" || "${confirm,,}" == "no" ]]; then
        log_info "Cancelled by user"
        exit 0
    fi
    echo ""

    # Print connection info
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "  VM: $VM_NAME"
    echo "  Memory: ${MEMORY}MB | CPUs: $CPUS"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    echo "  SSH access (after boot):  ssh -p $SSH_PORT user@localhost"
    echo ""
    if [[ ${#SHARED_DIRS[@]} -gt 0 ]]; then
        echo "  Mount shared directories:"
        local idx=0
        for dir in "${SHARED_DIRS[@]}"; do
            local tag="shared_dir_$idx"
            local basename=$(basename "$dir")
            echo "    sudo mkdir -p /mnt/$basename"
            echo "    sudo mount -t 9p -o trans=virtio,version=9p2000.L $tag /mnt/$basename"
            ((idx+=1))
        done
        echo ""
    fi
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""

    # Build QEMU command
    local qemu_cmd
    local common_opts=(
        -name "$VM_NAME"
        -m "$MEMORY"
        -smp "$CPUS,cores=$CPUS"
        -drive "file=$IMAGE_PATH,format=qcow2,if=virtio,cache=writeback"
        -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22"
        -device virtio-net-pci,netdev=net0
        -device qemu-xhci
        -device usb-kbd
        -device usb-tablet
    )

    # Add shared directories
    local idx=0
    for dir in "${SHARED_DIRS[@]}"; do
        local tag="shared_dir_$idx"
        common_opts+=(-virtfs "local,path=$dir,mount_tag=$tag,security_model=mapped-xattr,id=$tag")
        ((idx+=1))
    done

    if [[ "$arch" == "x86_64" ]]; then
        qemu_cmd="qemu-system-x86_64"
        common_opts+=(
            -cpu host
            -vga virtio
        )
        if [[ "$os" == "linux" ]]; then
            common_opts+=(-enable-kvm)
            common_opts+=(-display gtk,grab-on-hover=on)
        else
            common_opts+=(-accel hvf)
            common_opts+=(-display cocoa)
        fi
    else
        qemu_cmd="qemu-system-aarch64"
        common_opts+=(
            -machine virt,highmem=on
            -accel hvf
            -cpu host
            -bios "$UEFI_FIRMWARE"
            -device virtio-gpu-pci
        )
        if [[ "$os" == "linux" ]]; then
            common_opts+=(-display gtk,grab-on-hover=on)
        else
            common_opts+=(-display cocoa)
        fi
    fi

    log_info "Starting VM..."
    echo ""

    if [[ "${DEBUG:-0}" == "1" ]]; then
        log_info "QEMU command:"
        print_command "$qemu_cmd" "${common_opts[@]}"
    fi

    # Execute QEMU with proper argument handling
    set +e
    "$qemu_cmd" "${common_opts[@]}"
    local qemu_status=$?
    set -e
    if ((qemu_status != 0)); then
        log_error "QEMU exited with status $qemu_status"
        if [[ "${DEBUG:-0}" != "1" ]]; then
            log_info "Re-run with DEBUG=1 to print the full QEMU command"
        fi
        exit $qemu_status
    fi

    log_ok "VM shut down"
}

main "$@"