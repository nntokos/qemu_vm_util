#!/usr/bin/env bash
set -e

RED="\033[0;31m"
GREEN="\033[0;32m"
BLUE="\033[0;34m"
NC="\033[0m"

info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

usage() {
cat <<EOF
Usage: ./install-qemu.sh

What this script does:
  • Detects your operating system
  • Detects your CPU architecture
  • Checks whether QEMU is already installed
  • Installs QEMU system emulators if missing

Supported OS:
  • macOS
  • Ubuntu / Debian
  • Fedora
  • Arch Linux

Supported architectures:
  • x86_64
  • arm64 / aarch64

Safe to re-run multiple times.
EOF
}

[[ "$1" == "-h" || "$1" == "--help" ]] && usage && exit 0

info "Detecting operating system and CPU architecture..."

OS="$(uname -s)"
ARCH="$(uname -m)"

case "$ARCH" in
  x86_64|amd64)
    ARCH_NAME="x86_64"
    ;;
  arm64|aarch64)
    ARCH_NAME="ARM64 (AArch64)"
    ;;
  *)
    ARCH_NAME="Unknown ($ARCH)"
    ;;
esac

info "OS detected: $OS"
info "CPU architecture detected: $ARCH_NAME"

have_qemu() {
  command -v qemu-system-aarch64 >/dev/null 2>&1 || \
  command -v qemu-system-x86_64 >/dev/null 2>&1
}

if have_qemu; then
  ok "QEMU already installed"
  exit 0
fi

if [[ "$OS" == "Darwin" ]]; then
  info "macOS detected"

  command -v brew >/dev/null || error "Homebrew not found (https://brew.sh)"

  info "Installing QEMU via Homebrew..."
  brew install qemu
  ok "QEMU installed on macOS"

elif [[ "$OS" == "Linux" ]]; then
  [[ -f /etc/os-release ]] || error "Cannot detect Linux distribution"
  . /etc/os-release

  info "Linux distribution: $ID"

  case "$ID" in
    ubuntu|debian)
      sudo apt update
      sudo apt install -y \
        qemu-system-aarch64 \
        qemu-system-arm \
        qemu-system-x86 \
        qemu-utils \
        qemu-efi-aarch64
      ;;
    fedora)
      sudo dnf install -y \
        qemu-system-aarch64 \
        qemu-system-arm \
        qemu-system-x86
      ;;
    arch)
      sudo pacman -Sy --noconfirm qemu qemu-arch-extra
      ;;
    *)
      error "Unsupported Linux distribution: $ID"
      ;;
  esac

  ok "QEMU installed on Linux"

else
  error "Unsupported operating system: $OS"
fi

info "Available QEMU system emulators:"
command -v qemu-system-aarch64 >/dev/null && echo "  • qemu-system-aarch64"
command -v qemu-system-arm     >/dev/null && echo "  • qemu-system-arm"
command -v qemu-system-x86_64  >/dev/null && echo "  • qemu-system-x86_64"

ok "Setup complete"
