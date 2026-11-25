#!/usr/bin/env bash
#
# start_vm.sh - Boot a VM from an existing disk image (no cloning)
#
# Usage:
#   ./start_vm.sh <vm_name | image.qcow2> [options]
#
# Positional:
#   vm_name              Name given to create_vm.sh; boots images/<vm_name>.qcow2
#   image.qcow2          Or a path to any existing qcow2 disk image
#
# Options:
#   -n, --name NAME      Name for the VM (default: disk file name without .qcow2)
#   -m, --memory MB      Memory in MB (default: 4096)
#   -c, --cpus N         Number of CPU cores (default: 2)
#   -p, --ssh-port PORT  SSH port forwarding (default: 2222)
#   -d, --shared-dir DIR Directory to mount in VM (can be specified multiple times)
#   -e, --expose SPEC    Forward a host port to a guest port (can be specified
#                        multiple times). SPEC: [tcp:|udp:]HOST[:GUEST]
#                        e.g. 8080:80, 5353 (same port), udp:6000:6000
#       --internet       Allow the VM to reach the host network and internet.
#                        Default: isolated (only forwarded ports are reachable).
#   -r, --resolution WxH Guest screen resolution, which sets the window size
#                        (default: 1280x800). On Retina screens the window is half
#                        that size in points; use 2560x1600 for a 1280x800 window.
#       --efi PATH       Path to EFI/UEFI firmware (QEMU_EFI.fd).
#                        Default: the firmware shipped with QEMU, else ./efi/QEMU_EFI.fd
#   --config PATH, -f    YAML config profile to load defaults from.
#                        Default: ./config/default.yaml if present.
#                        CLI flags always override the config file.
#   -h, --help           Show this help message
#
# Example:
#   ./start_vm.sh ubuntu24
#   ./start_vm.sh ubuntu24 -n mytest -m 8192
#   ./start_vm.sh images/ubuntu24.qcow2 --efi ./efi/QEMU_EFI.fd
#   ./start_vm.sh ubuntu24 -d ~/myfiles -d ~/projects
#   ./start_vm.sh ubuntu24 --internet -e 8080:80 -e 3000

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=lib/efi.sh
source "$SCRIPT_DIR/lib/efi.sh"

# Defaults (overridden below by config profile, then by CLI flags)
SHARED_DIRS=()
CLI_EXPOSE_PORTS=()

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

    if [[ "$arch" == "arm64" ]]; then
        if [[ ! -f "$UEFI_FIRMWARE" ]]; then
            log_error "UEFI firmware not found: ${UEFI_FIRMWARE:-none detected}"
            log_error "Install QEMU's EDK2 firmware or provide it via --efi <path>"
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

# validate_expose_ports
# Checks every EXPOSE_PORTS entry against [tcp:|udp:]HOST[:GUEST] and port range.
validate_expose_ports() {
    local spec port failed=0
    for spec in "${EXPOSE_PORTS[@]}"; do
        if ! [[ "$spec" =~ ^((tcp|udp):)?([0-9]+)(:([0-9]+))?$ ]]; then
            log_error "Invalid --expose value: $spec (expected [tcp:|udp:]HOST[:GUEST])"
            ((failed+=1))
            continue
        fi
        for port in "${BASH_REMATCH[3]}" "${BASH_REMATCH[5]}"; do
            if [[ -n "$port" ]] && ((port < 1 || port > 65535)); then
                log_error "Port out of range in --expose $spec (valid range: 1-65535)"
                ((failed+=1))
            fi
        done
    done
    if ((failed > 0)); then
        exit 1
    fi
}

# expose_to_hostfwd SPEC
# Converts [tcp:|udp:]HOST[:GUEST] into a QEMU hostfwd rule, e.g. 8080:80 -> tcp::8080-:80.
expose_to_hostfwd() {
    local spec=$1 proto=tcp host guest
    if [[ "$spec" == tcp:* || "$spec" == udp:* ]]; then
        proto=${spec%%:*}
        spec=${spec#*:}
    fi
    host=${spec%%:*}
    guest=${spec#*:}
    printf '%s::%s-:%s' "$proto" "$host" "$guest"
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
    log_error "Missing required positional argument: <vm_name | image.qcow2>"
    echo ""
    usage
fi

IMAGE_PATH="$1"
shift
# A bare VM name resolves to the disk create_vm.sh made for it
if [[ ! -f "$IMAGE_PATH" && -f "$SCRIPT_DIR/images/$IMAGE_PATH.qcow2" ]]; then
    IMAGE_PATH="$SCRIPT_DIR/images/$IMAGE_PATH.qcow2"
fi

CONFIG_FILE="$(resolve_config_file "$SCRIPT_DIR/config/default.yaml" "$@")"
CONFIG_SECTION="start_vm"
[[ -n "$CONFIG_FILE" ]] && log_info "Using config profile: $CONFIG_FILE"

# Defaults (config profile overrides these; CLI flags override the config profile)
VM_NAME="$(cfg_get name "$(basename "$IMAGE_PATH" .qcow2)")"
MEMORY="$(cfg_get memory 4096)"
CPUS="$(cfg_get cpus 2)"
SSH_PORT="$(cfg_get ssh_port 2222)"
UEFI_FIRMWARE="$(cfg_get efi "$(find_efi_firmware)")"
INTERNET="$(cfg_get_bool internet 0)"
RESOLUTION="$(cfg_get resolution 1280x800)"
mapfile -t EXPOSE_PORTS < <(cfg_get_list expose)

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
        -e|--expose)
            CLI_EXPOSE_PORTS+=("$2")
            shift 2
            ;;
        --internet)
            INTERNET=1
            shift
            ;;
        -r|--resolution)
            RESOLUTION="$2"
            shift 2
            ;;
        --efi)
            UEFI_FIRMWARE="$2"
            shift 2
            ;;
        --config|-f)
            shift 2 # already resolved above
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

# CLI --expose replaces the config list rather than appending to it
if [[ ${#CLI_EXPOSE_PORTS[@]} -gt 0 ]]; then
    EXPOSE_PORTS=("${CLI_EXPOSE_PORTS[@]}")
fi

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
    if ! [[ "$RESOLUTION" =~ ^([1-9][0-9]*)x([1-9][0-9]*)$ ]]; then
        log_error "Resolution must be WIDTHxHEIGHT, e.g. 1920x1080, got: $RESOLUTION"
        exit 1
    fi
    local gpu_res="xres=${BASH_REMATCH[1]},yres=${BASH_REMATCH[2]}"
    if [[ ${#SHARED_DIRS[@]} -gt 0 ]]; then
        validate_shared_dirs
    fi
    if [[ ${#EXPOSE_PORTS[@]} -gt 0 ]]; then
        validate_expose_ports
    fi

    if [[ ! -f "$IMAGE_PATH" ]]; then
        log_error "Image not found: $IMAGE_PATH (also looked for $SCRIPT_DIR/images/$IMAGE_PATH.qcow2)"
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
    echo "    Resolution:     $RESOLUTION"
    echo "    SSH Port:       $SSH_PORT"
    if [[ "$INTERNET" == "1" ]]; then
        echo "    Internet:       enabled"
    else
        echo "    Internet:       disabled (use --internet to enable)"
    fi
    if [[ ${#EXPOSE_PORTS[@]} -gt 0 ]]; then
        echo "    Exposed ports:  ${EXPOSE_PORTS[*]}"
    fi
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
    if [[ ${#EXPOSE_PORTS[@]} -gt 0 ]]; then
        echo "  Exposed ports (host -> guest):"
        local spec
        for spec in "${EXPOSE_PORTS[@]}"; do
            echo "    $(expose_to_hostfwd "$spec")"
        done
        echo ""
    fi
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
    # restrict=on cuts the guest off from the host and internet; hostfwd rules still work
    local netdev="user,id=net0,hostfwd=tcp::${SSH_PORT}-:22"
    for spec in "${EXPOSE_PORTS[@]}"; do
        netdev+=",hostfwd=$(expose_to_hostfwd "$spec")"
    done
    if [[ "$INTERNET" != "1" ]]; then
        netdev+=",restrict=on"
    fi

    local qemu_cmd
    local common_opts=(
        -name "$VM_NAME"
        -m "$MEMORY"
        -smp "$CPUS,cores=$CPUS"
        -drive "file=$IMAGE_PATH,format=qcow2,if=virtio,cache=writeback"
        -netdev "$netdev"
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
            -device "virtio-vga,$gpu_res"
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
            -cpu host
            -bios "$UEFI_FIRMWARE"
            -device "virtio-gpu-pci,$gpu_res"
        )
        if [[ "$os" == "linux" ]]; then
            common_opts+=(-accel kvm)
            common_opts+=(-display gtk,grab-on-hover=on)
        else
            common_opts+=(-accel hvf)
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
