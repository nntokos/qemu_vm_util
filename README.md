# QEMU VM Quickstart (macOS & Linux)

This repository provides a **fast, repeatable workflow** to:

1. Install QEMU and required dependencies  
2. Create a new VM from an Ubuntu ISO (Desktop or Server)  
3. Boot, stop, and re-run the VM using an existing disk image  

The setup is designed to work cleanly on:

- **macOS** (Intel & Apple Silicon)
- **Linux** (Ubuntu, Debian, Fedora, Arch)

It is especially suited for **OS development, testing, and automation**.

---

## Repository Scripts

| Script | Purpose |
|------|--------|
| `install-qemu.sh` | Install QEMU and dependencies (auto-detects OS + CPU) |
| `create-vm.sh` | Create a new VM disk and boot an installer ISO |
| `start_vm.sh` | Start an existing VM disk (no cloning, no reinstall) |

---

## 1. Install QEMU (one-time)

Run once on a new machine:

```sh
chmod +x install-qemu.sh
./install-qemu.s
```
This script:
	•	Detects your operating system
	•	Detects CPU architecture (x86_64 or arm64/aarch64)
	•	Installs the correct QEMU system emulators
	•	Is safe to re-run at any time

Verify installation
```sh
qemu-system-aarch64 --version   # ARM64 hosts
qemu-system-x86_64 --version    # x86_64 host
```

## 2. Create a New VM
### Basic usage
```sh
./create-vm.sh <os.iso> <vm_name>
```

### Example (Ubuntu Desktop on ARM64):
```sh
./create-vm.sh ubuntu-24.04-desktop-arm64.iso ubuntu24
```
This will:
	•	Create ./ubuntu24/ubuntu24.qcow2
	•	Boot the ISO in a QEMU window
	•	Launch the installer

Available options:
	•	--disk-gb N – Disk size in GB (default: 32)
	•	--ram-mb N – RAM in MB (default: 4096)
	•	--cpus N – Number of vCPUs (default: 4)
	•	--ssh-port N – Host port forwarded to guest SSH (default: 2222)
	•	--headless – No GUI window (useful for servers)
	•	--no-accel – Force pure emulation (disable KVM/HVF)

### Autoinstall (optional)

If you already have a prebuilt autoinstall / seed ISO:
```sh
./create-vm.sh ubuntu-24.04-live-server-arm64.iso u24srv \
  --autoinstall-iso autoinstall.iso
```

Notes:
	•	The autoinstall ISO is attached as a second CD-ROM
	•	Some Ubuntu ISOs still require adding kernel parameters in GRUB:


## 3. Start an Existing VM (normal usage)

After installation completes, do not use create-vm.sh again.

Use start_vm.sh to boot the existing disk image.

### Basic start
```sh
./start_vm.sh ./ubuntu24/ubuntu24.qcow2
```

### With options
```sh
./start_vm.sh ./ubuntu24/ubuntu24.qcow2 \
  --name ubuntu24-test \
  --memory 8192 \
  --cpus 4 \
  --ssh-port 2222
```

## 4. Stop the VM
To stop the VM safely:
	•	Shut down from inside the guest OS, or
	•	Close the QEMU window

The disk image remains intact.


## 5. Typical Workflow
```sh
install_qemu.sh      # once per machine
create_vm.sh         # once per VM
start_vm.sh       # every time you want to boot the VM
```

## UEFI / EFI firmware (`--efi`)

On **ARM64 (AArch64)** VMs (`qemu-system-aarch64 -machine virt`), most modern installer ISOs
(Ubuntu Desktop/Server, etc.) require **UEFI (EDK2) firmware** to boot.

This project supports EFI in a deterministic, repo-first way.

### Default behavior (no flags)
If `--efi` is **not** provided, `create-vm.sh` will try the following in order:

1. Use the repo-provided firmware: ./efi/QEMU_EFI.fd
2. Auto-detect a system-installed firmware (e.g. from `qemu-efi-aarch64`)
3. Continue without EFI (some ISOs may fail to boot)

### Explicit override
You can force a specific EFI firmware file using `--efi`:

```sh
./create-vm.sh ubuntu-24.04-live-server-arm64.iso myvm \
--efi ./efi/QEMU_EFI.fd
```

Or with a custom firmware path:
```sh
./create-vm.sh ubuntu.iso myvm \
  --efi /path/to/custom/QEMU_EFI.fd
```
When --efi is provided, it always overrides the default and auto-detection logic.






