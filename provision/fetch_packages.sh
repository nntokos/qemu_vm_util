#!/usr/bin/env bash
# fetch_packages.sh - Download packages and their dependencies from a running VM into provision/repo/
#
# The VM must have internet (start_vm.sh --internet) and SSH, and should be a fresh
# overlay of the image you will later provision from: apt skips anything the VM
# already has installed, so the repository holds exactly what that image lacks.
# Replaces the current contents of provision/repo/ and shuts the VM down.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/console.sh"
source "$SCRIPT_DIR/../lib/remote.sh"

USAGE="Usage: provision/fetch_packages.sh <user@host> [-p PORT] [-l LIST]

  user@host      SSH target of the running VM, e.g. admin@localhost
  -p, --port     Host port forwarded to the guest's SSH (default: 2222)
  -l, --list     Package list (default: provision/packages.txt)

Example:
  ./create_vm.sh fetch-tmp --base ubuntu-server-clean
  ./start_vm.sh fetch-tmp --internet
  provision/fetch_packages.sh admin@localhost
  rm images/fetch-tmp.qcow2"

remote_parse "$USAGE" "$@"
PACKAGES="$(read_packages)"
[[ -n "$PACKAGES" ]] || { console_error "No packages listed in $PACKAGE_LIST"; exit 2; }
REPO="$SCRIPT_DIR/repo"
GUEST_REPO=/tmp/provision-repo

remote_connect
GUEST_USER="$(ssh "${SSH_OPTS[@]}" "$TARGET" id -un)"

console_info "Downloading in the guest: $PACKAGES"
remote_sudo "set -e
rm -rf $GUEST_REPO && mkdir -p $GUEST_REPO/partial
apt-get update
apt-get install -y --download-only -o Dir::Cache::archives=$GUEST_REPO $PACKAGES
rm -rf $GUEST_REPO/partial $GUEST_REPO/lock
cd $GUEST_REPO
apt-ftparchive packages . > Packages
apt-ftparchive release . > Release
chown -R $GUEST_USER $GUEST_REPO"

mkdir -p "$REPO"
remote_rsync "$TARGET:$GUEST_REPO/" "$REPO/"
count="$(find "$REPO" -name '*.deb' | wc -l | tr -d ' ')"
if [[ "$count" -eq 0 ]]; then
  console_warn "Nothing was downloaded; the VM already has every listed package"
else
  console_ok "Stored $count packages in $REPO"
fi

remote_poweroff
