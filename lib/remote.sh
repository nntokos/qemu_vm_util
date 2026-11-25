#!/usr/bin/env bash
# lib/remote.sh - shared SSH handling for provision/fetch_packages.sh and provision/provision.sh
#
# Sourced, not executed. Requires lib/console.sh to be sourced first.
# One shared SSH connection (ControlMaster) is opened per run, so the SSH
# password is asked once; sudo inside the guest still asks for its own.

# remote_parse USAGE ARGS...
# Sets TARGET (user@host), SSH_PORT (default 2222) and PACKAGE_LIST
# (default provision/packages.txt). Prints USAGE and exits on -h or bad input.
remote_parse() {
  local usage="$1"
  shift
  TARGET=""
  SSH_PORT=2222
  PACKAGE_LIST="$SCRIPT_DIR/packages.txt"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -p|--port) SSH_PORT="${2:-}"; shift 2 ;;
      -l|--list) PACKAGE_LIST="${2:-}"; shift 2 ;;
      -h|--help) printf '%s\n' "$usage"; exit 0 ;;
      -*) console_error "Unknown option: $1"; printf '%s\n' "$usage"; exit 2 ;;
      *)
        [[ -z "$TARGET" ]] || { console_error "Unexpected argument: $1"; exit 2; }
        TARGET="$1"; shift ;;
    esac
  done
  [[ -n "$TARGET" ]] || { console_error "Missing target (user@host)"; printf '%s\n' "$usage"; exit 2; }
  [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || { console_error "Port must be an integer: $SSH_PORT"; exit 2; }
  [[ -f "$PACKAGE_LIST" ]] || { console_error "Package list not found: $PACKAGE_LIST"; exit 2; }
}

# read_packages
# Prints the package names in PACKAGE_LIST on one line, ignoring comments and blank lines.
read_packages() {
  sed -e 's/#.*//' "$PACKAGE_LIST" | tr -s ' \t\n' ' ' | sed -e 's/^ //' -e 's/ $//'
}

# remote_connect
# Opens the shared connection and closes it when the calling script exits.
remote_connect() {
  SSH_SOCKET="$(mktemp -u "${TMPDIR:-/tmp}/qemu-vm-util-ssh.XXXXXX")"
  SSH_OPTS=(-p "$SSH_PORT" -o ControlPath="$SSH_SOCKET")
  console_info "Connecting to $TARGET on port $SSH_PORT"
  ssh "${SSH_OPTS[@]}" -o ControlMaster=yes -fN "$TARGET" || { console_fail "Could not connect to $TARGET"; exit 1; }
  trap 'ssh "${SSH_OPTS[@]}" -O exit "$TARGET" 2>/dev/null' EXIT
}

# remote_sudo SCRIPT
# Runs SCRIPT as root in the guest through bash, on a terminal so sudo can ask for a password.
remote_sudo() {
  ssh "${SSH_OPTS[@]}" -t "$TARGET" "sudo bash -c $(printf '%q' "$1")"
}

# remote_rsync SRC DEST
# rsync over the shared connection; prefix the guest side with "$TARGET:".
remote_rsync() {
  rsync -a --delete -e "ssh -p $SSH_PORT -o ControlPath=$SSH_SOCKET" "$1" "$2"
}

# remote_poweroff
# Schedules a guest shutdown a few seconds out, so the SSH session ends cleanly first.
remote_poweroff() {
  console_info "Shutting down the VM"
  remote_sudo "systemd-run --quiet --on-active=3 systemctl poweroff"
}
