# Images

| Image | Built from | Contents |
|---|---|---|
| `ubuntu-server-clean.qcow2` | `iso/ubuntu-24.04.3-live-server-arm64.iso` with `autoinstall.iso` | Ubuntu Server 24.04.3 (arm64), hostname `ubuntu-server`, user `admin` / `admin` with sudo. SSH by key only. Has `openssh-server`, `curl`, `git`, `vim`, `htop`, `build-essential` and `rsync` at their install-time versions. Lacks `net-tools`. |
| `basic.qcow2` | overlay of `ubuntu-server-clean.qcow2` | Everything in the clean image, plus every package in `provision/packages.txt` at the versions in `provision/repo/`. |

Both images are read-only. VMs are created from `basic` (`./create_vm.sh <vm_name> --base basic`).
