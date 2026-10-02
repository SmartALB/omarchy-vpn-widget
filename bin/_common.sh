#!/usr/bin/env bash
# Shared helpers of the smartalb.vpn scripts. Sourced, never executed.
#
# Both paths can be redirected through environment variables so that the
# tests neither read the real connection list nor call the real systemctl.

CONNECTIONS_FILE="${OMARCHY_VPN_CONNECTIONS:-$HOME/.config/omarchy/vpn-connections.json}"
SYSTEMCTL="${OMARCHY_VPN_SYSTEMCTL:-/usr/bin/systemctl}"

# The authenticated switching helper. A new path deliberately avoids reusing
# the old helper's NOPASSWD grant. install --system performs legacy migration.
#
# Redirectable here, not there: this script runs as the user, the helper
# program runs as root.
VPN_PRIVILEGED="${OMARCHY_VPN_PRIVILEGED:-/usr/local/bin/omarchy-vpn-switch}"

# Import and switching both use pkexec with auth_admin, without retention.
IMPORT_BIN="${OMARCHY_VPN_IMPORT:-/usr/local/bin/omarchy-vpn-import}"

# Upper bound for a read-only systemctl status call. Switching has a fixed
# root-side operation budget independent of this user-controlled setting.
# Not every unit bounds itself: wg-quick@<name> reports
# TimeoutStartUSec=infinity. 'list' calls unit_state() once per connection
# every 10s from the panel timer -- without this bound a stuck 'is-active'
# freezes the panel on the stale state for good, with no error message
# (review I5).
SYSTEMCTL_TIMEOUT="${OMARCHY_VPN_TIMEOUT:-90}"

need_jq() {
  command -v jq >/dev/null 2>&1 && return 0
  echo "${0##*/}: jq is not installed" >&2
  exit 3
}

# The connection list as a JSON array on stdout.
#
# Unlike a list of recently used things, a missing or broken file is NOT a
# harmless empty case here: without it the plugin can do nothing at all.
# That is why valid JSON always comes out, while the return value does
# distinguish "empty" from "unreadable".
#
# On top of 'type == array', every element is checked for 'type == object':
# 'jq -c .[]' aborts in the middle of the stream as soon as an element is
# not an object -- preceding entries would already have been printed, and
# following ones would vanish silently (exit 0, no error message). A single
# broken element invalidates the WHOLE file instead of quietly truncating
# the list (review I3).
# The state file is read before anything is capped, so its SIZE has to be
# bounded before jq ever parses it -- otherwise a padded or corrupted file
# exhausts the shell long before the 200-entry cap in 'list' applies
# (second review round). 200 entries are a few tens of kilobytes.
MAX_STATE_BYTES="${OMARCHY_VPN_MAX_STATE_BYTES:-262144}"

state_file_too_big() {
  local size
  size="$(stat -c %s "$CONNECTIONS_FILE" 2>/dev/null)" || return 1
  [ -n "$size" ] && [ "$size" -gt "$MAX_STATE_BYTES" ]
}

read_connections() {
  if state_file_too_big; then
    return 1
  fi
  if [ -r "$CONNECTIONS_FILE" ] && \
     jq -e 'type == "array" and all(.[]; type == "object")' "$CONNECTIONS_FILE" >/dev/null 2>&1; then
    jq -c . "$CONNECTIONS_FILE"
    return 0
  fi
  printf '[]\n'
  return 1
}

# State of a unit, boiled down to three values: active, failed, inactive.
#
# systemd knows more (activating, deactivating, reloading); for the display
# all that counts is whether the connection is up, whether it is broken, or
# whether it is neither. 'is-active' exits non-zero for everything except
# active, hence the || true -- otherwise it drags set-e callers down with
# it.
#
# This folding is meant for the DISPLAY ('list' and the panel) and stays
# that way deliberately -- see test_unit_state_never_empty. It is NOT
# suitable for the group check in toggle, see unit_needs_stop_for_group()
# below.
#
# '--' separates the unit from command options. This status query is unprivileged.
unit_state() {
  local unit="$1" state
  state="$(timeout "$SYSTEMCTL_TIMEOUT" "$SYSTEMCTL" is-active -- "$unit" 2>/dev/null)" || true
  case "$state" in
    active) printf 'active\n' ;;
    failed) printf 'failed\n' ;;
    *) printf 'inactive\n' ;;
  esac
}

# True (exit 0) when a unit still has to be touched for the group rule --
# that is, when it is NOT safely stopped. 'inactive' and 'failed' are the
# only states in which no tunnel is certainly up; everything else (active,
# activating, deactivating, reloading, ...) counts as "not safely stopped
# yet" and gets stopped.
#
# Unlike unit_state() this does NOT fold 'activating' into 'inactive':
# openvpn-client@.service is Type=notify with TimeoutStartUSec=90s and sits
# at 'activating' for the whole duration of establishing the connection. If
# the group rule folded the way unit_state() does, a slow partner start
# would look like 'inactive', the group exclusion would not take effect,
# and two tunnels of the same group would run at once (review C1).
#
# Deliberately a function of its own instead of extending unit_state():
# 'list' and the panel intentionally show only three states (active/failed/
# disconnected) -- if unit_state() itself returned 'activating', the panel
# would have to understand that fourth value as well, although the display
# does not need it. The group check gets its own, finer view of the same
# raw state instead.
unit_needs_stop_for_group() {
  local unit="$1" state
  state="$(timeout "$SYSTEMCTL_TIMEOUT" "$SYSTEMCTL" is-active -- "$unit" 2>/dev/null)" || true
  case "$state" in
    inactive|failed) return 1 ;;
    *) return 0 ;;
  esac
}
