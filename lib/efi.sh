#!/usr/bin/env bash
# lib/efi.sh - shared AArch64 UEFI firmware lookup for create_vm.sh / start_vm.sh
#
# Sourced, not executed. Requires SCRIPT_DIR to point at the repo root.

# find_efi_firmware
# Prints the first UEFI firmware found, or nothing. Firmware shipped with the
# installed QEMU comes first: the repo's efi/QEMU_EFI.fd is an older build that
# does not boot installed Ubuntu 24.04 disks, so it is only a last fallback.
find_efi_firmware() {
  local fw
  for fw in \
    /opt/homebrew/share/qemu/edk2-aarch64-code.fd \
    /usr/local/share/qemu/edk2-aarch64-code.fd \
    /usr/share/qemu-efi-aarch64/QEMU_EFI.fd \
    /usr/share/edk2/aarch64/QEMU_EFI.fd \
    "$SCRIPT_DIR/efi/QEMU_EFI.fd"
  do
    if [[ -f "$fw" ]]; then
      printf '%s' "$fw"
      return
    fi
  done
}
