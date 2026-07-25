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
Usage: ./install_deps.sh

What this script does:
  • Detects your operating system
  • Detects your CPU architecture
  • Installs QEMU system emulators if missing
  • Installs yq (mikefarah/yq), used to read config/*.yaml profiles

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
    YQ_ARCH="amd64"
    ;;
  arm64|aarch64)
    ARCH_NAME="ARM64 (AArch64)"
    YQ_ARCH="arm64"
    ;;
  *)
    ARCH_NAME="Unknown ($ARCH)"
    YQ_ARCH=""
    ;;
esac

info "OS detected: $OS"
info "CPU architecture detected: $ARCH_NAME"

have_qemu() {
  command -v qemu-system-aarch64 >/dev/null 2>&1 || \
  command -v qemu-system-x86_64 >/dev/null 2>&1
}

# Debian/Ubuntu ship an unrelated Python-based "yq" (kislyuk/yq) via apt.
# We specifically need mikefarah/yq (the Go binary, used for our config/*.yaml
# profiles), so we check the binary's own --version output rather than trusting
# `command -v yq` alone.
have_mikefarah_yq() {
  command -v yq >/dev/null 2>&1 || return 1
  yq --version 2>&1 | grep -qi "mikefarah"
}

if have_qemu; then
  ok "QEMU already installed"
else
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
fi

if have_mikefarah_yq; then
  ok "yq (mikefarah/yq) already installed"
else
  if command -v yq >/dev/null 2>&1; then
    info "Found a 'yq' on PATH that isn't mikefarah/yq (likely the Python kislyuk/yq package). Installing mikefarah/yq alongside it."
  fi

  if [[ "$OS" == "Darwin" ]]; then
    command -v brew >/dev/null || error "Homebrew not found (https://brew.sh)"
    info "Installing yq via Homebrew..."
    brew install yq
    ok "yq installed on macOS"

  elif [[ "$OS" == "Linux" ]]; then
    [[ -n "$YQ_ARCH" ]] || error "Unsupported CPU architecture for yq: $ARCH"
    command -v curl >/dev/null 2>&1 || error "curl is required to install yq"

    YQ_URL="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${YQ_ARCH}"
    info "Downloading yq (mikefarah/yq) for linux/${YQ_ARCH}..."
    TMP_YQ="$(mktemp)"
    curl -fsSL "$YQ_URL" -o "$TMP_YQ" || error "Failed to download yq from $YQ_URL"
    chmod +x "$TMP_YQ"
    sudo mv "$TMP_YQ" /usr/local/bin/yq
    ok "yq installed to /usr/local/bin/yq"

  else
    error "Unsupported operating system: $OS"
  fi
fi

info "Available QEMU system emulators:"
command -v qemu-system-aarch64 >/dev/null && echo "  • qemu-system-aarch64"
command -v qemu-system-arm     >/dev/null && echo "  • qemu-system-arm"
command -v qemu-system-x86_64  >/dev/null && echo "  • qemu-system-x86_64"
info "yq version:"
yq --version 2>/dev/null | sed 's/^/  • /'

ok "Setup complete"
