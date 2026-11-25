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
| `create_vm.sh` | Create a new VM disk and boot an installer ISO, or create a disk from a base image |
| `start_vm.sh` | Start an existing VM disk (no cloning, no reinstall) |
| `provision/fetch_packages.sh` | Download packages from a VM with internet into a local apt repository |
| `provision/provision.sh` | Install packages into a VM from that repository, without internet |

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
	•	Create images/ubuntu24.qcow2 (inside the repo, wherever you run the script from)
	•	Boot the ISO in a QEMU window
	•	Launch the installer

Available options:
	•	--disk-gb N – Disk size in GB (default: 32)
	•	--ram-mb N – RAM in MB (default: 4096)
	•	--cpus N – Number of vCPUs (default: 4)
	•	--ssh-port N – Host port forwarded to guest SSH (default: 2222)
	•	--headless – No GUI window (useful for servers)
	•	--no-accel – Force pure emulation (disable KVM/HVF)
	•	--base IMAGE – Create the disk from an existing image instead of an ISO (see [Base image and offline provisioning](#base-image-and-offline-provisioning))
	•	--copy – With --base, make an independent full copy instead of an overlay
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
Pass the VM name used with `create_vm.sh`, or a path to any `.qcow2` disk:
```sh
./start_vm.sh ubuntu24                  # boots images/ubuntu24.qcow2
./start_vm.sh /path/to/other.qcow2
```

### With options
```sh
./start_vm.sh ubuntu24 \
  --name ubuntu24-test \
  --memory 8192 \
  --cpus 4 \
  --ssh-port 2222
```

Available options:
	•	--name NAME / -n – VM name (default: disk file name without .qcow2)
	•	--memory MB / -m – RAM in MB (default: 4096)
	•	--cpus N / -c – Number of vCPUs (default: 2)
	•	--ssh-port N / -p – Host port forwarded to guest SSH (default: 2222)
	•	--expose SPEC / -e – Forward a host port to a guest port, repeatable. SPEC is `[tcp:|udp:]HOST[:GUEST]` (e.g. `8080:80`, `3000`, `udp:6000:6000`)
	•	--internet – Allow the VM to reach the host network and internet (default: isolated)
	•	--resolution WxH / -r – Guest screen resolution, which sets the window size (default: 1280x800). On Retina screens the window appears at half that size, so use 2560x1600 for a 1280x800 window
	•	--efi PATH – EFI/UEFI firmware path (arm64 only; see [UEFI / EFI firmware](#uefi--efi-firmware---efi))
	•	--config PATH / -f PATH – YAML config profile to load defaults from (see [Config profiles](#config-profiles))

### Networking
The VM uses QEMU user-mode networking. By default it is isolated (`restrict=on`): it cannot reach
the host or the internet, but the SSH port and any `--expose` ports remain reachable from the host.
Pass `--internet` to lift the restriction.

```sh
./start_vm.sh ubuntu24 --internet -e 8080:80 -e 3000
```

### Enabling SSH inside the VM
Both scripts forward host port 2222 (or `--ssh-port`) to guest port 22, but the guest needs an SSH server.
VMs created from the base image already have one (see [Base image and offline provisioning](#base-image-and-offline-provisioning)).

**Ubuntu Server:** tick *Install OpenSSH server* in the installer. Nothing else is needed.

**Ubuntu Desktop (or if you skipped it):** installing packages needs internet access, so boot with `--internet` once:
```sh
./start_vm.sh ubuntu24 --internet
```
Then, inside the VM:
```sh
sudo apt update
sudo apt install -y openssh-server
sudo systemctl enable --now ssh
```
From the host (use the username created during installation):
```sh
ssh -p 2222 <user>@localhost
ssh-copy-id -p 2222 <user>@localhost   # optional: key login instead of password
```
SSH keeps working on later boots without `--internet`, since forwarded ports are reachable in isolated mode.

## 4. Stop the VM
To stop the VM safely:
	•	Shut down from inside the guest OS, or
	•	Close the QEMU window

The disk image remains intact.


## 5. Typical Workflow
```sh
install_deps.sh                    # once per machine
create_vm.sh <vm_name> --base basic # once per VM (see below for building the base)
start_vm.sh <vm_name>              # every time you want to boot the VM
```

## Base image and offline provisioning

New VMs are created from a provisioned base image instead of installing from an ISO each time:

```
images/ubuntu-server-clean.qcow2   fresh install + admin user, read-only
  └─ images/basic.qcow2            clean + packages from provision/packages.txt, read-only
       └─ images/<vm_name>.qcow2   one per VM
```

By default `create_vm.sh --base` creates an **overlay**: a disk that stores only its differences
from the image below it, so it is created instantly and takes little space. Booting and using an
overlay is safe. Modifying the image *below* it is not and corrupts every overlay built on it,
which is why the lower images are made read-only. With `--copy` the new disk is an independent
full copy instead.

What each image contains is listed in [images/README.md](images/README.md).

All VMs log in as `admin` / `admin`. SSH uses your key (`ssh -p 2222 admin@localhost`), since
password login over SSH is disabled.

### Prepare the clean image (once)
Do this before any overlay of the clean image exists, since it modifies the image:
```sh
chmod u+w images/ubuntu-server-clean.qcow2
./start_vm.sh ubuntu-server-clean
```
Log in as the installation user (for `autoinstall.iso`: `nikolaosntokos` / `12345678`) and run:
```sh
sudo useradd -m -s /bin/bash -G sudo admin
echo admin:admin | sudo chpasswd
sudo install -d -m 700 -o admin -g admin /home/admin/.ssh
sudo install -m 600 -o admin -g admin ~/.ssh/authorized_keys /home/admin/.ssh/
sudo hostnamectl set-hostname ubuntu-server
sudo sed -i "s/^127.0.1.1 .*/127.0.1.1 ubuntu-server/" /etc/hosts
exit
```
Log in again as `admin`, then:
```sh
sudo deluser --remove-home nikolaosntokos
sudo poweroff
```
```sh
chmod a-w images/ubuntu-server-clean.qcow2
```

### Fetch the packages (once, needs internet)
`provision/packages.txt` lists the packages for `basic`; add your own there. Fetch them from a
fresh overlay of the clean image. apt skips packages the VM already has, so the repository holds
exactly what the clean image lacks:
```sh
./create_vm.sh fetch-tmp --base ubuntu-server-clean
./start_vm.sh fetch-tmp --internet
provision/fetch_packages.sh admin@localhost    # in another terminal; shuts the VM down
rm images/fetch-tmp.qcow2
```
The packages and their dependencies are stored in `provision/repo/` (git-ignored) as a local apt
repository.

### Apply the packages (no internet)
Start the VM to provision and, once the login prompt shows, run `provision.sh` from another
terminal. It copies the repository into the VM, installs the listed packages from it, removes the
copy and shuts the VM down.

To build `basic`, so every VM has the packages:
```sh
./create_vm.sh basic --base ubuntu-server-clean
./start_vm.sh basic
provision/provision.sh admin@localhost         # in another terminal
chmod a-w images/basic.qcow2
```
To provision a single VM instead:
```sh
./create_vm.sh myvm --base basic
./start_vm.sh myvm
provision/provision.sh admin@localhost         # in another terminal
```

Both scripts connect over SSH, take `-p PORT` (default 2222) and `-l LIST` (default
`provision/packages.txt`), and ask for the guest's sudo password twice (once for the work, once
for the shutdown). A repository only matches the image it was fetched from. If SSH reports a
changed host key, run `ssh-keygen -R "[localhost]:2222"`.

To change `basic` later, build a new base the same way. Existing VMs stay tied to the old one.

## UEFI / EFI firmware (`--efi`)

On **ARM64 (AArch64)** VMs (`qemu-system-aarch64 -machine virt`), most modern installer ISOs
(Ubuntu Desktop/Server, etc.) require **UEFI (EDK2) firmware** to boot.

### Default behavior (no flags)
If `--efi` is **not** provided, both scripts use the first firmware found:

1. The EDK2 firmware shipped with QEMU (Homebrew `share/qemu/edk2-aarch64-code.fd`, or the
   distribution's `qemu-efi-aarch64` / `edk2` package on Linux)
2. The repo copy `./efi/QEMU_EFI.fd`, an older build that does not boot installed Ubuntu 24.04 disks
3. None (`create_vm.sh` continues without firmware; `start_vm.sh` stops with an error)

The firmware is loaded with `-bios`, which accepts a firmware file of any size.

### Explicit override
You can force a specific EFI firmware file using `--efi`:

```sh
./create_vm.sh ubuntu-24.04-live-server-arm64.iso myvm \
  --efi /opt/homebrew/share/qemu/edk2-aarch64-code.fd
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
./start_vm.sh ubuntu24 --config config/profiles/desktop-arm64.yaml
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


