#!/usr/bin/env bash
# lib/config.sh - shared YAML config loading for create_vm.sh / start_vm.sh
#
# Precedence for every setting: CLI flag > config/*.yaml value > script's
# built-in default. Sourced, not executed.
#
# Requires mikefarah/yq (Go binary) on PATH. If yq or the config file are
# missing, every lookup silently falls back to the caller-supplied default,
# so the scripts keep working exactly as before with no config file at all.

# find_config_flag ARGS...
# Scans args for --config/-f PATH or --config=PATH; prints the path (or nothing).
find_config_flag() {
  local args=("$@") i
  for ((i = 0; i < ${#args[@]}; i++)); do
    case "${args[$i]}" in
      --config|-f)
        printf '%s' "${args[$((i + 1))]:-}"
        return
        ;;
      --config=*)
        printf '%s' "${args[$i]#*=}"
        return
        ;;
    esac
  done
}

# resolve_config_file DEFAULT_PATH ARGS...
# Prints the config file to use: an explicit --config/-f value (must exist,
# fatal otherwise), else DEFAULT_PATH if it exists, else nothing.
resolve_config_file() {
  local default_path="$1" explicit
  shift
  explicit="$(find_config_flag "$@")"
  if [[ -n "$explicit" ]]; then
    [[ -f "$explicit" ]] || { echo "Config file not found: $explicit" >&2; exit 1; }
    printf '%s' "$explicit"
  elif [[ -f "$default_path" ]]; then
    printf '%s' "$default_path"
  fi
}

# cfg_get KEY DEFAULT
# Looks up ".$CONFIG_SECTION.KEY", falling back to ".common.KEY", then
# DEFAULT. Requires CONFIG_FILE and CONFIG_SECTION to be set by the caller.
cfg_get() {
  local key="$1" default="$2" val

  [[ -n "${CONFIG_FILE:-}" ]] || { printf '%s' "$default"; return; }
  command -v yq >/dev/null 2>&1 || { printf '%s' "$default"; return; }

  val="$(yq eval ".${CONFIG_SECTION}.${key} // .common.${key} // \"\"" "$CONFIG_FILE" 2>/dev/null)"
  if [[ -z "$val" || "$val" == "null" ]]; then
    printf '%s' "$default"
  else
    printf '%s' "$val"
  fi
}

# cfg_get_bool KEY DEFAULT(0|1)
# Same as cfg_get but maps YAML true/false to 1/0.
cfg_get_bool() {
  local key="$1" default="$2" val
  val="$(cfg_get "$key" "")"
  case "$val" in
    true)  printf '1' ;;
    false) printf '0' ;;
    *)     printf '%s' "$default" ;;
  esac
}
