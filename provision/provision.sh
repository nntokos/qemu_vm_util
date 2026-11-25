#!/usr/bin/env bash
# provision.sh - Install packages into a running VM from provision/repo/, without internet
#
# Copies the repository into the guest, installs the listed packages using only that
# repository (the guest's own apt sources and package lists are left untouched),
# removes the copy and shuts the VM down.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/console.sh"
source "$SCRIPT_DIR/../lib/remote.sh"

USAGE="Usage: provision/provision.sh <user@host> [-p PORT] [-l LIST]

  user@host      SSH target of the running VM, e.g. admin@localhost
  -p, --port     Host port forwarded to the guest's SSH (default: 2222)
  -l, --list     Package list (default: provision/packages.txt)

Example:
  ./create_vm.sh myvm --base basic
  ./start_vm.sh myvm
  provision/provision.sh admin@localhost"

remote_parse "$USAGE" "$@"
PACKAGES="$(read_packages)"
[[ -n "$PACKAGES" ]] || { console_error "No packages listed in $PACKAGE_LIST"; exit 2; }
REPO="$SCRIPT_DIR/repo"
[[ -f "$REPO/Packages" ]] || { console_error "No repository in $REPO; run provision/fetch_packages.sh first"; exit 2; }
GUEST_REPO=/tmp/provision-repo
GUEST_LISTS=/tmp/provision-lists
GUEST_SOURCE=/tmp/provision.list

remote_connect
console_info "Copying the repository into the guest"
remote_rsync "$REPO/" "$TARGET:$GUEST_REPO/"

console_info "Installing: $PACKAGES"
APT_OPTS="-o Dir::Etc::SourceList=$GUEST_SOURCE -o Dir::Etc::SourceParts=- -o Dir::State::Lists=$GUEST_LISTS"
remote_sudo "set -e
trap 'rm -rf $GUEST_REPO $GUEST_LISTS $GUEST_SOURCE' EXIT
mkdir -p $GUEST_LISTS/partial
echo 'deb [trusted=yes] file:$GUEST_REPO ./' > $GUEST_SOURCE
apt-get $APT_OPTS update
apt-get $APT_OPTS install -y $PACKAGES"
console_ok "Packages installed"

remote_poweroff
