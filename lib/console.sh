# ----------------------------------------------------------------
# Vendored from shadburn 0.0.1 (commit 39c229f)
# Body SHA-256: bc98f8eb9149a0cc4d4965c3231287e6b93dd77f8b31521e698fe8e1b5025be0
# Do not edit; update with shadburn vendor console
# ----------------------------------------------------------------
# ================================================================
# File: console.sh
# Purpose: Console output standard shared by shadburn and pylothouse.
#          One mark per line, then one space and the message.
#          Only the mark is coloured.
# Usage: Source only. Self-contained and compatible with Bash 3.2.
# Requires: –
# ================================================================

# -----------------------------------------------------
# Function: console_colour
# Purpose : Decide whether output to a file descriptor gets colour. Colour
#           requires a terminal, an unset NO_COLOR (an empty value also
#           disables colour) and a TERM containing "256color" or "direct".
# Usage   : console_colour 1 && echo "colour on stdout"
# Input:
#   $1: File descriptor number
# Output: Returns 0 when colour should be used, 1 otherwise
# -----------------------------------------------------
console_colour() {
  [ -t "$1" ] || return 1
  [ -z "${NO_COLOR+set}" ] || return 1
  case "${TERM:-}" in
    *256color*|*direct*) return 0 ;;
  esac
  return 1
}

# -----------------------------------------------------
# Function: _console_line
# Purpose : Print one marked line. Internal.
# Input:
#   $1: File descriptor (1 or 2)
#   $2: ANSI colour code (e.g. 32)
#   $3: Mark (e.g. [✓])
#   $@: Message
# -----------------------------------------------------
_console_line() {
  local fd="$1" code="$2" mark="$3"
  shift 3
  if console_colour "$fd"; then
    printf '\033[%sm%s\033[0m %s\n' "$code" "$mark" "$*" >&"$fd"
  else
    printf '%s %s\n' "$mark" "$*" >&"$fd"
  fi
}

# -----------------------------------------------------
# Function: console_ok / console_fail / console_error / console_warn / console_info
# Purpose : Print a marked message.
#           ok    [✓]       green,  stdout: success
#           fail  [✗]       red,    stderr: an operation ran and did not succeed
#           error [ERROR]   red,    stderr: the command could not run
#           warn  [WARNING] yellow, stderr
#           info  [i]       blue,   stdout
# Usage   : console_ok "Build finished"
# Input:
#   $@: Message
# -----------------------------------------------------
console_ok()    { _console_line 1 32 '[✓]' "$@"; }
console_fail()  { _console_line 2 31 '[✗]' "$@"; }
console_error() { _console_line 2 31 '[ERROR]' "$@"; }
console_warn()  { _console_line 2 33 '[WARNING]' "$@"; }
console_info()  { _console_line 1 34 '[i]' "$@"; }

# -----------------------------------------------------
# Function: console_act
# Purpose : Ask for confirmation. Prints "[Act] <message>: " to stdout and
#           reads one line from stdin. End of input declines.
# Usage   : console_act "Delete the cache? Type yes" || exit 1
#           console_act "Type the project name" "shadburn"
# Input:
#   $1: Message
#   $2: Expected answer (default: yes)
# Output: Returns 0 only when the answer matches exactly, 1 otherwise
# -----------------------------------------------------
console_act() {
  local message="$1" expected="${2:-yes}" reply=""
  if console_colour 1; then
    printf '\033[33m[Act]\033[0m %s: ' "$message"
  else
    printf '[Act] %s: ' "$message"
  fi
  if ! IFS= read -r reply; then
    printf '\n'
    return 1
  fi
  [ "$reply" = "$expected" ]
}
