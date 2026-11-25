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
| `install_deps.sh` | Install QEMU and yq (auto-detects OS + CPU) |
| `create_vm.sh` | Create a new VM disk and boot an installer ISO |
| `start_vm.sh` | Start an existing VM disk (no cloning, no reinstall) |

---

## 1. Install dependencies (one-time)

Run once on a new machine:

```sh
chmod +x install_deps.sh
./install_deps.sh
```
This script:
	•	Detects your operating system
	•	Detects CPU architecture (x86_64 or arm64/aarch64)
	•	Installs the correct QEMU system emulators
	•	Installs yq (mikefarah/yq), used to read config/*.yaml profiles
	•	Is safe to re-run at any time

Verify installation
```sh
qemu-system-aarch64 --version   # ARM64 hosts
qemu-system-x86_64 --version    # x86_64 host
```

## 2. Create a New VM
### Basic usage
```sh
./create_vm.sh <os.iso> <vm_name>
```

### Example (Ubuntu Desktop on ARM64):
```sh
./create_vm.sh ubuntu-24.04-desktop-arm64.iso ubuntu24
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
	•	--config PATH / -f PATH – YAML config profile to load defaults from (see [Config profiles](#config-profiles))

### Autoinstall (optional)

If you already have a prebuilt autoinstall / seed ISO:
```sh
./create_vm.sh ubuntu-24.04-live-server-arm64.iso u24srv \
  --autoinstall-iso autoinstall.iso
```

Notes:
	•	The autoinstall ISO is attached as a second CD-ROM
	•	Some Ubuntu ISOs still require adding kernel parameters in GRUB:


## 3. Start an Existing VM (normal usage)

After installation completes, do not use create_vm.sh again.

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

Available options:
	•	--name NAME / -n – VM name (default: test-<timestamp>)
	•	--memory MB / -m – RAM in MB (default: 4096)
	•	--cpus N / -c – Number of vCPUs (default: 2)
	•	--ssh-port N / -p – Host port forwarded to guest SSH (default: 2222)
	•	--expose SPEC / -e – Forward a host port to a guest port, repeatable. SPEC is `[tcp:|udp:]HOST[:GUEST]` (e.g. `8080:80`, `3000`, `udp:6000:6000`)
	•	--internet – Allow the VM to reach the host network and internet (default: isolated)
	•	--efi PATH – EFI/UEFI firmware path (arm64 only)
	•	--config PATH / -f PATH – YAML config profile to load defaults from (see [Config profiles](#config-profiles))

### Networking
The VM uses QEMU user-mode networking. By default it is isolated (`restrict=on`): it cannot reach
the host or the internet, but the SSH port and any `--expose` ports remain reachable from the host.
Pass `--internet` to lift the restriction.

```sh
./start_vm.sh ./ubuntu24/ubuntu24.qcow2 --internet -e 8080:80 -e 3000
```

## 4. Stop the VM
To stop the VM safely:
	•	Shut down from inside the guest OS, or
	•	Close the QEMU window

The disk image remains intact.


## 5. Typical Workflow
```sh
install_deps.sh      # once per machine
create_vm.sh         # once per VM
start_vm.sh           # every time you want to boot the VM
```

## UEFI / EFI firmware (`--efi`)

On **ARM64 (AArch64)** VMs (`qemu-system-aarch64 -machine virt`), most modern installer ISOs
(Ubuntu Desktop/Server, etc.) require **UEFI (EDK2) firmware** to boot.

This project supports EFI in a deterministic, repo-first way.

### Default behavior (no flags)
If `--efi` is **not** provided, `create_vm.sh` will try the following in order:

1. Use the repo-provided firmware: ./efi/QEMU_EFI.fd
2. Auto-detect a system-installed firmware (e.g. from `qemu-efi-aarch64`)
3. Continue without EFI (some ISOs may fail to boot)

### Explicit override
You can force a specific EFI firmware file using `--efi`:

```sh
./create_vm.sh ubuntu-24.04-live-server-arm64.iso myvm \
--efi ./efi/QEMU_EFI.fd
```

Or with a custom firmware path:
```sh
./create_vm.sh ubuntu.iso myvm \
  --efi /path/to/custom/QEMU_EFI.fd
```
When --efi is provided, it always overrides the default and auto-detection logic.

## Config profiles

`create_vm.sh` and `start_vm.sh` read their defaults from a YAML profile instead of
only from hardcoded values. Precedence, highest to lowest:

1. **CLI flag** (e.g. `--ram-mb 8192`) — always wins
2. **YAML config profile** — loaded via `--config`/`-f`, or `./config/default.yaml` if it exists
3. **Script's built-in default** — used if a key is unset or `null` in the config, or no config file is found at all

This means the scripts behave exactly as before if you never touch `config/`.

`config/default.yaml` ships with every key set to `null` (defer to built-in defaults). To
change your day-to-day defaults, edit that file directly. For situational overrides
(e.g. a beefier profile for desktop installs), create a separate file under
`config/profiles/` and pass it explicitly:

```sh
./create_vm.sh ubuntu-24.04-desktop-arm64.iso ubuntu24 --config config/profiles/desktop-arm64.yaml
./start_vm.sh ./images/ubuntu24.qcow2 --config config/profiles/desktop-arm64.yaml
```

A profile is a plain YAML file with three optional sections:

```yaml
common:      # shared keys, used by both scripts unless overridden below
  cpus: 6
  ssh_port: 2222
  efi: null

create_vm:   # create_vm.sh-only keys (override common: for the same key)
  disk_gb: 64
  ram_mb: 8192
  autoinstall_iso: null
  headless: false
  no_accel: false

start_vm:    # start_vm.sh-only keys (override common: for the same key)
  memory: 8192
  internet: true
  expose: ["8080:80", "3000"]   # CLI --expose replaces this list
```

Requires `yq` (mikefarah/yq, installed by `install_deps.sh`). If `yq` isn't on `PATH`,
config lookups silently fall through to the script's built-in defaults (see precedence above).


