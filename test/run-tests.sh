#!/usr/bin/env bash
# Test suite for the helper scripts of the smartalb.vpn plugin.
# No framework: every test function is named test_*, runs in a subshell of
# its own with a throwaway HOME and stubbed system commands.
set -uo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$PLUGIN_DIR/bin"
PASS=0
FAIL=0

fail() {
  printf '     %s\n' "$@" >&2
  exit 1
}

assert_eq() {
  [ "$1" = "$2" ] || fail "expected: $2" "got: $1"
}

assert_contains() {
  case "$1" in
    *"$2"*) ;;
    *) fail "expected substring: $2" "in: $1" ;;
  esac
}

# Creates a throwaway HOME and an EXCLUSIVE PATH: only the stub directory
# and a symlink farm of the tools actually needed. Merely prepending the
# stub directory is not enough -- a test that removes a stub would
# otherwise find the real program and check nothing.
#
# Control files that individual tests may set:
#   $SANDBOX/state/<unit>   -> what 'systemctl is-active <unit>' reports
#   $SANDBOX/systemctl.log  -> every systemctl call, one line per call
#   $SANDBOX/sudo.log       -> every sudo call, one line per call
#   $SANDBOX/fail-start     -> if present, every 'start' fails
#   $SANDBOX/fail-stop      -> if present, every 'stop' fails
#   $SANDBOX/hang-start     -> if present, every 'start' hangs (for the timeout)
#   $SANDBOX/hang-stop      -> if present, every 'stop' hangs
#   $SANDBOX/hang-is-active -> if present, every 'is-active' hangs (for the timeout)
#   $SANDBOX/sudo-denies    -> if present, 'sudo -n' refuses
#   $SANDBOX/pkexec.log     -> every pkexec call, one line per call
#   $SANDBOX/pkexec-cancels -> if present, pkexec aborts with 126
setup_sandbox() {
  SANDBOX="$(mktemp -d)"
  trap 'rm -rf "$SANDBOX"' EXIT
  export HOME="$SANDBOX/home"
  mkdir -p "$HOME/.config/omarchy" "$SANDBOX/stub" "$SANDBOX/sysbin" "$SANDBOX/state"

  mkdir -p "$SANDBOX/sysbin"
  local tool
  local toolpath
  for tool in bash jq sed grep tail head cut cat mktemp mv rm mkdir basename dirname readlink env printf sort ln timeout sleep cmp stat sha256sum wc tr find mkfifo install id tar; do
    toolpath="$(command -v "$tool" 2>/dev/null)"
    if [ -n "$toolpath" ]; then
      ln -sf "$toolpath" "$SANDBOX/sysbin/$tool"
    else
      echo "setup_sandbox: tool not found: $tool" >&2
    fi
  done

  cat >"$SANDBOX/stub/systemctl" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$SANDBOX/systemctl.log"
action="\${1:-}"; shift || true
# Skip --dry-run and --, so that the unit name is what is left over.
unit=""
for a in "\$@"; do case "\$a" in --*|-) ;; *) unit="\$a";; esac; done
statefile="$SANDBOX/state/\$unit"
case "\$action" in
  is-active)
    # exec instead of a plain 'sleep', for the same reason as at 'start'
    # below: 'timeout' has to be able to hit the process directly.
    [ -e "$SANDBOX/hang-is-active" ] && exec sleep 5
    if [ -r "\$statefile" ]; then cat "\$statefile"; else echo inactive; fi
    [ "\$(cat "\$statefile" 2>/dev/null)" = active ] && exit 0 || exit 3
    ;;
  start)
    # exec instead of a plain 'sleep': the script replaces itself with
    # sleep instead of starting it as a child process. Only that way does
    # the SIGTERM from 'timeout' hit the process holding the pipe open
    # directly -- otherwise an orphaned sleep would be left behind and the
    # command substitution in the test would wait for the full sleep
    # instead of for the timeout.
    [ -e "$SANDBOX/hang-start" ] && exec sleep 5
    [ -e "$SANDBOX/fail-start" ] && { echo "Job for \$unit failed." >&2; exit 1; }
    echo active >"\$statefile"; exit 0 ;;
  stop)
    [ -e "$SANDBOX/hang-stop" ] && exec sleep 5
    [ -e "$SANDBOX/fail-stop" ] && { echo "Job for \$unit failed." >&2; exit 1; }
    echo inactive >"\$statefile"; exit 0 ;;
  *) exit 0 ;;
esac
STUB

  cat >"$SANDBOX/stub/sudo" <<STUB
#!/usr/bin/env bash
# One line per invocation: the argument list can itself be a whole script,
# and a raw dump would make a single call look like fifty.
printf '%s\n' "\${*//$'\\n'/ }" >>"$SANDBOX/sudo.log"
# Swallows -n and runs the rest directly -- or refuses.
[ "\${1:-}" = "-n" ] && shift
if [ -e "$SANDBOX/sudo-denies" ]; then
  echo "sudo: a password is required" >&2
  exit 1
fi
exec "\$@"
STUB

  # Stands in for the sudoers syntax check. The real visudo would have to
  # be given a file it accepts; here the verdict is switchable, because what
  # matters is what 'install --system' does with a REJECTION -- it must not
  # put the file into place.
  # The sandbox cannot confer privilege: 'install -o root -g root' would fail
  # on the ownership change, and the caller would see a failure that exists
  # only because we are not root. This stub drops the two options and passes
  # everything else through -- mode and content, which the tests do check,
  # stay untouched. It sits in stub/, ahead of sysbin/ in PATH, so it also
  # applies inside a script that sudo starts.
  cat >"$SANDBOX/stub/install" <<STUB
#!/usr/bin/env bash
args=()
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o|-g) shift 2 ;;
    *) args+=("\$1"); shift ;;
  esac
done
exec "$SANDBOX/sysbin/install" "\${args[@]}"
STUB

  cat >"$SANDBOX/stub/visudo" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$SANDBOX/visudo.log"
if [ -e "$SANDBOX/visudo-rejects" ]; then
  echo "\${3:-}: syntax error near line 1 <<<" >&2
  exit 1
fi
echo "\${3:-}: parsed OK"
STUB

  cat >"$SANDBOX/stub/pkexec" <<STUB
#!/usr/bin/env bash
# Stands in for the password dialog. Runs the command -- or aborts with
# 126, like the real pkexec when the user dismisses the dialog.
printf '%s\n' "\$*" >>"$SANDBOX/pkexec.log"
if [ -e "$SANDBOX/pkexec-cancels" ]; then
  echo "Error executing command as another user: Request dismissed" >&2
  exit 126
fi
exec "\$@"
STUB

  # A runnable copy of the helper program in which the hard-wired
  # systemctl assignment points at the stub. The original deliberately
  # reads nothing from the environment (it runs as root through a NOPASSWD
  # rule with no argument restriction), so there would otherwise be no way
  # to keep it away from the real systemctl.
  mkdir -p "$SANDBOX/priv"
  if [ ! -r "$PLUGIN_DIR/share/omarchy-vpn-privileged" ]; then
    echo "setup_sandbox: share/omarchy-vpn-privileged is missing" >&2
    exit 1
  fi
  sed 's#^SYSTEMCTL=/usr/bin/systemctl$#SYSTEMCTL=systemctl#' \
    "$PLUGIN_DIR/share/omarchy-vpn-privileged" >"$SANDBOX/priv/omarchy-vpn-privileged"
  # A hard safeguard: a silently failed substitution would let a real
  # 'systemctl start' loose on a real VPN unit.
  if grep -q '/usr/bin/systemctl' "$SANDBOX/priv/omarchy-vpn-privileged"; then
    echo "setup_sandbox: substitution failed, the copy still points at /usr/bin/systemctl" >&2
    exit 1
  fi
  chmod +x "$SANDBOX/priv/omarchy-vpn-privileged"

  # Second copy: the import program, with its target directories pointing
  # into the sandbox. As with the switching program, the original
  # deliberately reads nothing from the environment -- it runs as root
  # through pkexec.
  mkdir -p "$SANDBOX/etc/openvpn/client" "$SANDBOX/etc/wireguard"
  if [ ! -r "$PLUGIN_DIR/share/omarchy-vpn-import" ]; then
    echo "setup_sandbox: share/omarchy-vpn-import is missing" >&2
    exit 1
  fi
  sed -e "s#^OPENVPN_DIR=/etc/openvpn/client\$#OPENVPN_DIR=$SANDBOX/etc/openvpn/client#" \
      -e "s#^WIREGUARD_DIR=/etc/wireguard\$#WIREGUARD_DIR=$SANDBOX/etc/wireguard#" \
      "$PLUGIN_DIR/share/omarchy-vpn-import" >"$SANDBOX/priv/omarchy-vpn-import"
  # A positive test instead of a negative pattern (Review Important 1): a
  # negative pattern is only ever as good as the list of reformattings one
  # happened to think of -- an earlier attempt with an anchored "no longer
  # points at /etc" pattern caught quoting, say, but not
  # "OPENVPN_DIR=/etc/openvpn/client   # comment", not
  # "readonly OPENVPN_DIR=...", not "/etc/openvpn/./client". Here it is
  # checked directly instead that both lines point EXACTLY (`-x`) and
  # literally (`-F`) into the sandbox -- anything else is a failure, no
  # matter what it looks like.
  if ! grep -Fxq "OPENVPN_DIR=$SANDBOX/etc/openvpn/client" "$SANDBOX/priv/omarchy-vpn-import" ||
     ! grep -Fxq "WIREGUARD_DIR=$SANDBOX/etc/wireguard" "$SANDBOX/priv/omarchy-vpn-import"; then
    echo "setup_sandbox: substitution failed, the copy does not point into the sandbox" >&2
    exit 1
  fi
  # Review I7: the check above proves "a RIGHT line is there", not "no
  # WRONG one". A second assignment not hit by the sed pattern (say
  # "OPENVPN_DIR=/etc/openvpn/client  # comment" further down) would
  # silently override the substituted one -- and the suite would write into
  # the real /etc. That exact shape was the near-accident back in task 2.
  # Hence, additionally: there is EXACTLY ONE assignment per variable.
  if [ "$(grep -c '^OPENVPN_DIR=' "$SANDBOX/priv/omarchy-vpn-import")" != "1" ] ||
     [ "$(grep -c '^WIREGUARD_DIR=' "$SANDBOX/priv/omarchy-vpn-import")" != "1" ]; then
    echo "setup_sandbox: more than one directory assignment in the copy -- a later one could override the substituted one" >&2
    exit 1
  fi
  chmod +x "$SANDBOX/priv/omarchy-vpn-import"

  # A SECOND, unmodified copy -- byte-identical to
  # share/omarchy-vpn-privileged -- exclusively for the install tests of
  # the cmp check (Review Important 1). The copy above in $SANDBOX/priv is
  # deliberately bent (SYSTEMCTL points at the stub) and therefore ALWAYS
  # different from the original as far as 'cmp' is concerned; an install
  # test that wants to check the real good case (contents agree) must not
  # point at that copy but at this one.
  mkdir -p "$SANDBOX/priv-installed"
  cp "$PLUGIN_DIR/share/omarchy-vpn-privileged" \
    "$SANDBOX/priv-installed/omarchy-vpn-privileged"
  chmod 755 "$SANDBOX/priv-installed/omarchy-vpn-privileged"

  # A stand-in for the polkit action that 'install' expects under
  # OMARCHY_VPN_POLICY. Without a sandbox path of its own, 'install' would
  # read the REAL file under /usr/share/polkit-1/actions/ during the tests
  # -- not a test but a chance hit on whichever machine happens to run it.
  # The content is irrelevant, 'install' only checks -r.
  mkdir -p "$SANDBOX/polkit-actions"
  printf '<policyconfig/>\n' >"$SANDBOX/polkit-actions/org.omarchy.smartalbvpn.import.policy"

  # 'chmod' is deliberately absent from the symlink farm below (see the
  # comment at the install tests) -- 'install' itself must not find its own
  # chmod call on the plugin files in the exclusive PATH. Individual tests
  # do have to be able to produce wrong permissions on a sandbox copy on
  # purpose, though; so save the real chmod path here, BEFORE the PATH is
  # switched over.
  TEST_CHMOD="$(command -v chmod)"

  # 'cp' is not in the symlink farm either -- not deliberately kept out like
  # chmod, simply because no program under test needs it. Adding it would
  # weaken what the farm proves. One test copies the whole plugin, so it
  # gets the real path the same way.
  TEST_CP="$(command -v cp)"

  # Likewise awk: no program under test uses it, so it stays out of the
  # farm. One test parses Panel.qml's nesting with it.
  TEST_AWK="$(command -v awk)"

  chmod +x "$SANDBOX"/stub/*
  export PATH="$SANDBOX/stub:$SANDBOX/sysbin"
  export OMARCHY_VPN_CONNECTIONS="$HOME/.config/omarchy/vpn-connections.json"
  export OMARCHY_VPN_SYSTEMCTL="systemctl"
  export OMARCHY_VPN_PRIVILEGED="$SANDBOX/priv/omarchy-vpn-privileged"
  export OMARCHY_VPN_IMPORT="$SANDBOX/priv/omarchy-vpn-import"
  export OMARCHY_VPN_POLICY="$SANDBOX/polkit-actions/org.omarchy.smartalbvpn.import.policy"
  mkdir -p "$SANDBOX/sudoers.d"
  export OMARCHY_VPN_SUDOERS="$SANDBOX/sudoers.d/smartalb-vpn"

  write_connections <<'JSON'
[
  { "id": "example-29", "label": "Example 29",        "unit": "openvpn-client@Example_29", "group": "provider" },
  { "id": "example-26", "label": "Example 26",        "unit": "openvpn-client@Example_26", "group": "provider" },
  { "id": "wg-home",    "label": "WireGuard HomeNet", "unit": "wg-quick@HomeNet" }
]
JSON
}

write_connections() {
  cat >"$OMARCHY_VPN_CONNECTIONS"
}

set_state() {
  printf '%s\n' "$2" >"$SANDBOX/state/$1"
}

run_test() {
  local name="$1" out
  if out="$(setup_sandbox; "$name" 2>&1)"; then
    printf 'ok   %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf 'FAIL %s\n%s\n' "$name" "$out"
    FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------- Tests

test_harness_sandbox_is_isolated() {
  assert_contains "$PATH" "$SANDBOX/stub"
  case "$PATH" in *"/usr/bin"*) fail "PATH is not exclusive: $PATH" ;; esac
  assert_eq "$(jq -r 'length' "$OMARCHY_VPN_CONNECTIONS")" "3"
}

test_harness_systemctl_stub_tracks_state() {
  set_state "wg-quick@HomeNet" active
  assert_eq "$(systemctl is-active wg-quick@HomeNet)" "active"
  systemctl stop wg-quick@HomeNet
  assert_eq "$(systemctl is-active wg-quick@HomeNet)" "inactive"
  assert_contains "$(cat "$SANDBOX/systemctl.log")" "stop wg-quick@HomeNet"
}

test_read_connections_returns_array() {
  . "$BIN/_common.sh"
  local out rc=0
  out="$(read_connections)" || rc=$?
  assert_eq "$rc" "0"
  assert_eq "$(printf '%s' "$out" | jq -r 'length')" "3"
}

test_read_connections_missing_file_is_error() {
  . "$BIN/_common.sh"
  rm -f "$CONNECTIONS_FILE"
  local out rc=0
  out="$(read_connections)" || rc=$?
  assert_eq "$rc" "1"
  assert_eq "$(printf '%s' "$out" | jq -c .)" "[]"
}

test_read_connections_broken_file_is_error() {
  . "$BIN/_common.sh"
  printf 'not json' >"$CONNECTIONS_FILE"
  local rc=0
  read_connections >/dev/null || rc=$?
  assert_eq "$rc" "1"
}

test_read_connections_object_is_error() {
  . "$BIN/_common.sh"
  printf '{"not":"array"}' >"$CONNECTIONS_FILE"
  local rc=0
  read_connections >/dev/null || rc=$?
  assert_eq "$rc" "1"
}

# Shows I3: an array element that is not an object invalidates the WHOLE
# file instead of quietly truncating the list. Without the
# all(.[]; type == "object") check, 'jq -c .[]' would abort mid-stream on
# '[{a}, "broken", {b}]': only {a} would come out, exit 0, and {b} would
# vanish without any error message -- with a running tunnel behind it, that
# tunnel could no longer be switched off from the panel.
test_read_connections_non_object_element_is_error() {
  . "$BIN/_common.sh"
  printf '[{"id":"a"}, "broken", {"id":"b"}]' >"$CONNECTIONS_FILE"
  local rc=0
  read_connections >/dev/null || rc=$?
  assert_eq "$rc" "1"
}

test_unit_state_active() {
  . "$BIN/_common.sh"
  set_state "wg-quick@HomeNet" active
  assert_eq "$(unit_state wg-quick@HomeNet)" "active"
}

test_unit_state_failed() {
  . "$BIN/_common.sh"
  set_state "wg-quick@HomeNet" failed
  assert_eq "$(unit_state wg-quick@HomeNet)" "failed"
}

test_unit_state_unknown_is_inactive() {
  . "$BIN/_common.sh"
  assert_eq "$(unit_state does-not-exist.service)" "inactive"
}

# Pins down the folding of 'activating' into 'inactive' as the INTENDED
# behavior of unit_state() -- but only for the display (list/panel), which
# deliberately knows just three states. For the group check in toggle this
# very folding is the bug from review C1: there
# unit_needs_stop_for_group() applies (separate test below), which
# deliberately does NOT fold 'activating' into 'inactive'. Whoever reads
# this test on its own and concludes that an 'activating' partner is
# harmless for the group exclusion is wrong -- and that exact false
# conclusion slipped through every review so far.
test_unit_state_never_empty() {
  . "$BIN/_common.sh"
  set_state "wg-quick@HomeNet" activating
  local s
  s="$(unit_state wg-quick@HomeNet)"
  [ -n "$s" ] || fail "unit_state returned an empty string"
  assert_eq "$s" "inactive"
}

# Shows unit_needs_stop_for_group() directly: 'activating' counts as "not
# safely stopped yet" and has to lead to a stop.
test_unit_needs_stop_for_group_activating() {
  . "$BIN/_common.sh"
  set_state "wg-quick@HomeNet" activating
  unit_needs_stop_for_group "wg-quick@HomeNet" || \
    fail "activating should have counted as 'must be stopped'"
}

test_unit_needs_stop_for_group_inactive_is_false() {
  . "$BIN/_common.sh"
  if unit_needs_stop_for_group "wg-quick@HomeNet"; then
    fail "inactive should NOT have counted as 'must be stopped'"
  fi
}

test_unit_needs_stop_for_group_failed_is_false() {
  . "$BIN/_common.sh"
  set_state "wg-quick@HomeNet" failed
  if unit_needs_stop_for_group "wg-quick@HomeNet"; then
    fail "failed should NOT have counted as 'must be stopped'"
  fi
}

# Shows that unit_state does not drag a 'set -e' caller down with it at the
# '|| true' behind is-active. errexit does not apply inside a subshell that
# is the operand of '||' -- hence a real child process here instead of
# ( set -e; ... ) || rc=$?.
test_unit_state_survives_errexit_caller() {
  # Deliberately does NOT call unit_state inside $(...): by default bash
  # does not inherit errexit into a command substitution (inherit_errexit is
  # off), so the function body would run there without errexit and the test
  # would be blind to exactly the regression it is meant to show.
  local rc=0
  bash -c '
    set -euo pipefail
    . "$1/_common.sh"
    unit_state does-not-exist.service >/dev/null
  ' _ "$BIN" || rc=$?
  assert_eq "$rc" "0"
}

# Separate from the errexit safeguard above: this checks the value that
# comes back. Deliberately through $(...), i.e. the normal case of every
# real caller.
test_unit_state_survives_errexit_caller_reports_inactive() {
  local rc=0
  local out
  out="$(bash -c '
    set -euo pipefail
    . "$1/_common.sh"
    unit_state does-not-exist.service
  ' _ "$BIN")" || rc=$?
  assert_eq "$rc" "0"
  assert_eq "$out" "inactive"
}

# Shows need_jq: without jq in PATH, omarchy-vpn-list must fail with exit 3.
# need_jq uses no jq for its error message but plain echo, so the stderr
# message stays readable even without jq.
test_list_without_jq_exits_3_with_message() {
  local out err rc=0 jq_path
  jq_path="$(readlink -f "$(command -v jq)")"
  rm -f "$SANDBOX/sysbin/jq"
  out="$("$BIN/omarchy-vpn-list" --json 2>"$SANDBOX/stderr.tmp")" || rc=$?
  err="$(cat "$SANDBOX/stderr.tmp")"
  assert_eq "$rc" "3"
  assert_contains "$err" "jq is not installed"
  # Chicken and egg: without jq in PATH the JSON output cannot be checked
  # with jq. jq really was absent during the call above -- for the check we
  # put it back afterwards.
  ln -sf "$jq_path" "$SANDBOX/sysbin/jq"
  assert_eq "$(printf '%s' "$out" | jq -r 'type')" "object"
  assert_contains "$(printf '%s' "$out" | jq -r '.error')" "jq is not installed"
}

test_list_reports_all_connections() {
  local out
  out="$("$BIN/omarchy-vpn-list" --json)"
  assert_eq "$(printf '%s' "$out" | jq -r 'length')" "3"
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].id')" "example-29"
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].label')" "Example 29"
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].unit')" "openvpn-client@Example_29"
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].group')" "provider"
}

test_list_adds_state_per_connection() {
  local out
  set_state "wg-quick@HomeNet" active
  set_state "openvpn-client@Example_26" failed
  out="$("$BIN/omarchy-vpn-list" --json)"
  assert_eq "$(printf '%s' "$out" | jq -r '.[] | select(.id=="wg-home") | .state')" "active"
  assert_eq "$(printf '%s' "$out" | jq -r '.[] | select(.id=="example-26") | .state')" "failed"
  assert_eq "$(printf '%s' "$out" | jq -r '.[] | select(.id=="example-29") | .state')" "inactive"
}

test_list_group_is_null_when_absent() {
  local out
  out="$("$BIN/omarchy-vpn-list" --json)"
  assert_eq "$(printf '%s' "$out" | jq -r '.[] | select(.id=="wg-home") | .group')" "null"
}

test_list_reports_unreadable_config_as_error() {
  local out rc=0
  rm -f "$OMARCHY_VPN_CONNECTIONS"
  out="$("$BIN/omarchy-vpn-list" --json)" || rc=$?
  assert_eq "$rc" "5"
  assert_contains "$(printf '%s' "$out" | jq -r '.error')" "not readable"
}

# Shows I3 at the level of 'list': a broken element in the array must not
# silently swallow the rest of the list -- the whole call has to be
# recognizable as an error, not as a shortened but seemingly complete
# list.
test_list_reports_non_object_element_as_error() {
  local out rc=0
  write_connections <<'JSON'
[{"id":"a","label":"A","unit":"wg-quick@HomeNet"}, "broken", {"id":"b","label":"B","unit":"openvpn-client@Example_29"}]
JSON
  out="$("$BIN/omarchy-vpn-list" --json)" || rc=$?
  assert_eq "$rc" "5"
  assert_eq "$(printf '%s' "$out" | jq -r 'type')" "object"
}

# Shows I2: an entry without "label" must not let the unit name slip into
# the label field (the old @tsv/IFS splitting collapsed consecutive tabs
# and shifted the fields). "unit" has to stay the actual unit name, and
# "group" must not disappear.
test_list_entry_without_label_keeps_unit_and_group() {
  local out
  write_connections <<'JSON'
[{ "id": "example-29", "unit": "openvpn-client@Example_29", "group": "provider" }]
JSON
  out="$("$BIN/omarchy-vpn-list" --json)"
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].unit')" "openvpn-client@Example_29"
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].group')" "provider"
  # unit_state() may only have been called with the correct unit name, not
  # with garbage assembled from shifted fields.
  set_state "openvpn-client@Example_29" active
  out="$("$BIN/omarchy-vpn-list" --json)"
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].state')" "active"
}

# Shows I2 for the second case named there: an empty "id" must not end up
# in the output as an entry with an empty identifier.
test_list_skips_entry_with_empty_id() {
  local out
  write_connections <<'JSON'
[{ "id": "", "label": "No id", "unit": "wg-quick@HomeNet" }]
JSON
  out="$("$BIN/omarchy-vpn-list" --json)"
  assert_eq "$(printf '%s' "$out" | jq -c .)" "[]"
}

# Regression test from the fix round: a real TAB *inside the value* of
# "label" (not a missing field as above) is exactly the class of bug that
# triggered the rewrite to jq normalization -- the old '@tsv' splitting used
# tab as the field separator, so a tab INSIDE the content of a field would
# have been indistinguishable from an end of field and would have shifted
# id/unit/group/state.
#
# The tab is deliberately produced with 'printf' and written into the
# configuration file through 'jq -n --arg', not as heredoc text with a typed
# '\t': that guarantees the variable holds a single real tab BYTE (0x09) and
# not the two-character sequence backslash+t. The length check below shows
# that objectively (12 = 6+1+5 for "Before"+tab+"After", not 13 as it
# would be for a two-character sequence instead of a single tab byte).
# Checked by hand with 'od -c' on the generated file: there the file
# correctly contains the JSON escape sequence '\' 't' (two characters in
# the JSON TEXT -- that is how jq writes a tab character; a raw tab byte
# would even be invalid JSON at that position), while the value parsed back
# with 'jq -r' is a single real tab byte again.
test_list_entry_with_tab_in_label_keeps_fields() {
  local out label_with_tab
  label_with_tab="$(printf 'Before\tAfter')"
  [ "${#label_with_tab}" -eq 12 ] || \
    fail "faulty test setup: label_with_tab does not have the expected length (a real tab byte?)"

  jq -n --arg id "tab-1" --arg label "$label_with_tab" \
    --arg unit "wg-quick@HomeNet" --arg group "grp" \
    '[{id: $id, label: $label, unit: $unit, group: $group}]' \
    >"$OMARCHY_VPN_CONNECTIONS"

  set_state "wg-quick@HomeNet" active
  out="$("$BIN/omarchy-vpn-list" --json)"
  assert_eq "$(printf '%s' "$out" | jq -r 'length')" "1"
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].id')" "tab-1"
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].unit')" "wg-quick@HomeNet"
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].group')" "grp"
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].state')" "active"
  # Additionally shows that the tab byte itself comes through the
  # normalization intact, not merely that the other fields survive.
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].label')" "$label_with_tab"
}

# The same principle as above, this time with a real NEWLINE in the value of
# "label". For anything reading line by line with 'read' (as
# 'omarchy-vpn-list' did per entry before the rewrite) a newline would be
# the end of the line -- the rest of the entry would have been cut off or
# would have slipped into the next entry.
test_list_entry_with_newline_in_label_keeps_fields() {
  local out label_with_newline
  label_with_newline="$(printf 'Line1\nLine2')"
  [ "${#label_with_newline}" -eq 11 ] || \
    fail "faulty test setup: label_with_newline does not have the expected length (a real newline?)"

  jq -n --arg id "nl-1" --arg label "$label_with_newline" \
    --arg unit "openvpn-client@Example_29" --arg group "provider" \
    '[{id: $id, label: $label, unit: $unit, group: $group}]' \
    >"$OMARCHY_VPN_CONNECTIONS"

  set_state "openvpn-client@Example_29" failed
  out="$("$BIN/omarchy-vpn-list" --json)"
  assert_eq "$(printf '%s' "$out" | jq -r 'length')" "1"
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].id')" "nl-1"
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].unit')" "openvpn-client@Example_29"
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].group')" "provider"
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].state')" "failed"
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].label')" "$label_with_newline"
}

# Shows I5: 'list' has to bound every 'unit_state' call, just as 'toggle'
# does for its systemctl calls. Without the bound, a hanging 'is-active'
# would block the call indefinitely and the panel would freeze on the stale
# state. The outer 'timeout 5' is a safety net of the test suite itself --
# if the bound inside 'list' fails, the test should fail instead of hanging
# the whole run.
test_list_bounds_hanging_unit_state() {
  local out rc=0
  export OMARCHY_VPN_TIMEOUT=1
  : >"$SANDBOX/hang-is-active"
  out="$(timeout 5 "$BIN/omarchy-vpn-list" --json)" || rc=$?
  assert_eq "$rc" "0"
  assert_eq "$(printf '%s' "$out" | jq -r 'length')" "3"
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].state')" "inactive"
}

test_list_empty_config_is_empty_array() {
  local out rc=0
  printf '[]' >"$OMARCHY_VPN_CONNECTIONS"
  out="$("$BIN/omarchy-vpn-list" --json)" || rc=$?
  assert_eq "$rc" "0"
  assert_eq "$(printf '%s' "$out" | jq -c .)" "[]"
}

test_list_without_json_flag_is_usage_error() {
  local out rc=0
  out="$("$BIN/omarchy-vpn-list" 2>/dev/null)" || rc=$?
  assert_eq "$rc" "1"
  assert_eq "$(printf '%s' "$out" | jq -r 'type')" "object"
  assert_contains "$(printf '%s' "$out" | jq -r '.error')" "--json"
}

test_toggle_starts_inactive_connection() {
  "$BIN/omarchy-vpn-toggle" wg-home || fail "toggle failed"
  assert_contains "$(cat "$SANDBOX/systemctl.log")" "start wg-quick@HomeNet"
  assert_eq "$(cat "$SANDBOX/state/wg-quick@HomeNet")" "active"
}

test_toggle_stops_active_connection() {
  set_state "wg-quick@HomeNet" active
  "$BIN/omarchy-vpn-toggle" wg-home || fail "toggle failed"
  assert_contains "$(cat "$SANDBOX/systemctl.log")" "stop wg-quick@HomeNet"
  assert_eq "$(cat "$SANDBOX/state/wg-quick@HomeNet")" "inactive"
}

test_toggle_treats_failed_as_not_running() {
  set_state "wg-quick@HomeNet" failed
  "$BIN/omarchy-vpn-toggle" wg-home || fail "toggle failed"
  assert_contains "$(cat "$SANDBOX/systemctl.log")" "start wg-quick@HomeNet"
  case "$(cat "$SANDBOX/systemctl.log")" in
    *"stop wg-quick@HomeNet"*) fail "a failed unit should not have been stopped" ;;
  esac
}

test_toggle_stops_group_partner_before_starting() {
  set_state "openvpn-client@Example_29" active
  "$BIN/omarchy-vpn-toggle" example-26 || fail "toggle failed"
  # The order is the point: partner down first, then the new one up.
  local stop_line start_line log
  log="$(grep -n "openvpn-client" "$SANDBOX/systemctl.log")"
  stop_line="$(printf '%s' "$log" | grep "stop openvpn-client@Example_29" | cut -d: -f1)"
  start_line="$(printf '%s' "$log" | grep "start openvpn-client@Example_26" | cut -d: -f1)"
  [ -n "$stop_line" ] || fail "the group partner was not stopped"
  [ -n "$start_line" ] || fail "the target was not started"
  [ "$stop_line" -lt "$start_line" ] || fail "the start came before the stop of the partner"
}

# The core evidence for C1: a partner that is still 'activating' (a slow
# OpenVPN handshake, Type=notify with TimeoutStartUSec=90s) has to be
# stopped BEFORE its sibling entry is started -- otherwise two tunnels of
# the same group run at once. Before the fix the group rule compared against
# unit_state() = "active", and 'activating' folds to 'inactive' there: the
# partner was overlooked and stayed up while the second one came up.
test_toggle_stops_group_partner_when_activating() {
  set_state "openvpn-client@Example_29" activating
  "$BIN/omarchy-vpn-toggle" example-26 || fail "toggle failed"
  local log
  log="$(cat "$SANDBOX/systemctl.log")"
  case "$log" in
    *"stop openvpn-client@Example_29"*) ;;
    *) fail "the activating partner was not stopped -- two tunnels ran at once" ;;
  esac
  local stop_line start_line
  stop_line="$(printf '%s' "$log" | grep -n "stop openvpn-client@Example_29" | cut -d: -f1)"
  start_line="$(printf '%s' "$log" | grep -n "start openvpn-client@Example_26" | cut -d: -f1)"
  [ "$stop_line" -lt "$start_line" ] || fail "the start came before the stop of the activating partner"
}

test_toggle_leaves_other_groups_alone() {
  set_state "wg-quick@HomeNet" active
  set_state "openvpn-client@Example_29" active
  "$BIN/omarchy-vpn-toggle" example-26 || fail "toggle failed"
  assert_eq "$(cat "$SANDBOX/state/wg-quick@HomeNet")" "active"
  case "$(cat "$SANDBOX/systemctl.log")" in
    *"stop wg-quick@HomeNet"*) fail "WireGuard should not have been touched" ;;
  esac
}

test_toggle_does_not_start_when_partner_stop_fails() {
  local rc=0
  set_state "openvpn-client@Example_29" active
  : >"$SANDBOX/fail-stop"
  "$BIN/omarchy-vpn-toggle" example-26 >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "4"
  case "$(cat "$SANDBOX/systemctl.log")" in
    *"start openvpn-client@Example_26"*) fail "the start should have been left out" ;;
  esac
}

test_toggle_reports_start_failure() {
  local rc=0 out
  : >"$SANDBOX/fail-start"
  out="$("$BIN/omarchy-vpn-toggle" wg-home 2>&1)" || rc=$?
  assert_eq "$rc" "4"
  assert_contains "$out" "failed:"
}

test_toggle_reports_denied_sudo() {
  local rc=0 out
  : >"$SANDBOX/sudo-denies"
  out="$("$BIN/omarchy-vpn-toggle" wg-home 2>&1)" || rc=$?
  assert_eq "$rc" "4"
  assert_contains "$out" "password"
}

test_toggle_rejects_unknown_id() {
  local rc=0
  "$BIN/omarchy-vpn-toggle" doesnotexist >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "2"
  [ ! -f "$SANDBOX/systemctl.log" ] || \
    case "$(cat "$SANDBOX/systemctl.log")" in
      *start*|*stop*) fail "nothing should have been switched" ;;
    esac
}

# Shows I4: an entry without "unit" must NOT lead to 'systemctl start null'
# (the string "null", because that is exactly what 'jq -r .unit' returns for
# a missing field without a default). Instead: exit 5 (configuration error,
# see the comment in omarchy-vpn-toggle), no systemctl call at all, and a
# message that points at the configuration file rather than at sudoers.
test_toggle_rejects_missing_unit() {
  local rc=0 out
  write_connections <<'JSON'
[{ "id": "broken", "label": "Broken entry" }]
JSON
  out="$("$BIN/omarchy-vpn-toggle" broken 2>&1)" || rc=$?
  assert_eq "$rc" "5"
  assert_contains "$out" "unit"
  case "$out" in
    *null*) fail "the message must not point at a unit named 'null'" ;;
  esac
  [ ! -s "$SANDBOX/systemctl.log" ] || fail "systemctl should never have been called"
}

test_toggle_rejects_empty_unit() {
  local rc=0
  write_connections <<'JSON'
[{ "id": "broken", "label": "Broken entry", "unit": "" }]
JSON
  "$BIN/omarchy-vpn-toggle" broken >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "5"
  [ ! -s "$SANDBOX/systemctl.log" ] || fail "systemctl should never have been called"
}

test_toggle_without_argument_is_usage_error() {
  local rc=0
  "$BIN/omarchy-vpn-toggle" >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1"
}

test_toggle_reports_unreadable_config() {
  local rc=0
  rm -f "$OMARCHY_VPN_CONNECTIONS"
  "$BIN/omarchy-vpn-toggle" wg-home >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "5"
}

# Shows the fix from fix round 1: wg-quick@HomeNet has no
# TimeoutStartUSec and would hang indefinitely without the 'timeout' wrapper
# in run_systemctl. OMARCHY_VPN_TIMEOUT keeps the test short, and the stub
# 'systemctl' sleeps longer than that so the timeout really takes effect
# instead of the normal success path.
test_toggle_start_timeout_reports_it_and_exits_distinctly() {
  local rc=0 out
  export OMARCHY_VPN_TIMEOUT=1
  : >"$SANDBOX/hang-start"
  out="$("$BIN/omarchy-vpn-toggle" wg-home 2>&1)" || rc=$?
  assert_eq "$rc" "6"
  assert_contains "$out" "timed out after"
  case "$(cat "$SANDBOX/state/wg-quick@HomeNet" 2>/dev/null)" in
    active) fail "the timeout should not have reported the unit as active" ;;
  esac
}

# Shows the core change of the privilege model: 'toggle' no longer calls
# 'sudo systemctl' but 'sudo <helper program>'. Without this test somebody
# could put the old line back and see nothing but green tests -- the stub
# systemctl logs the same thing in both cases.
test_toggle_calls_privileged_helper() {
  "$BIN/omarchy-vpn-toggle" wg-home || fail "toggle failed"
  local sudolog
  sudolog="$(cat "$SANDBOX/sudo.log")"
  assert_contains "$sudolog" "$OMARCHY_VPN_PRIVILEGED start wg-quick@HomeNet"
  case "$sudolog" in
    *"systemctl start"*|*"systemctl stop"*)
      fail "toggle still calls systemctl directly through sudo" "log: $sudolog" ;;
  esac
}

# If the helper program is missing entirely -- never installed, or not
# copied again after a plugin update -- sudo reports "command not found".
# That has to reach the user too, instead of ending in a silent
# non-reaction.
test_toggle_reports_missing_helper() {
  local rc=0 out
  export OMARCHY_VPN_PRIVILEGED="$SANDBOX/doesnotexist/omarchy-vpn-privileged"
  out="$("$BIN/omarchy-vpn-toggle" wg-home 2>&1)" || rc=$?
  assert_eq "$rc" "4"
  assert_contains "$out" "failed:"
}

# The counterpart from the user's point of view: a connection list with a
# unit that the helper program does not let through. Previously the sudoers
# allowlist would have caught that and reported "a password is required" --
# a pointer at the wrong suspect. Now the rejection reaches the user
# together with its reason.
test_toggle_reports_helper_rejection() {
  local rc=0 out
  write_connections <<'JSON'
[{ "id": "evil", "label": "Foreign unit", "unit": "sshd" }]
JSON
  out="$("$BIN/omarchy-vpn-toggle" evil 2>&1)" || rc=$?
  assert_eq "$rc" "4"
  assert_contains "$out" "disallowed unit name"
  assert_contains "$out" "sshd"
  [ ! -e "$SANDBOX/systemctl.log" ] || \
    case "$(cat "$SANDBOX/systemctl.log")" in
      *start*|*stop*) fail "nothing should have been switched" ;;
    esac
}

# ------------------------------------------------ omarchy-vpn-privileged
#
# The helper program is the only piece of code that runs as root through
# sudo, and the sudoers rule does NOT restrict its arguments -- these
# checks are the entire gate. Every rejection here has been counter-checked
# by mutation: take the check out and the matching test turns red.
#
# What runs is the copy from $SANDBOX/priv (see setup_sandbox): in the
# original, /usr/bin/systemctl is hard-wired.

priv() { "$OMARCHY_VPN_PRIVILEGED" "$@"; }

assert_no_systemctl_call() {
  [ -e "$SANDBOX/systemctl.log" ] || return 0
  case "$(cat "$SANDBOX/systemctl.log")" in
    *start*|*stop*) fail "nothing should have been switched" \
                         "Log: $(cat "$SANDBOX/systemctl.log")" ;;
  esac
}

test_privileged_copy_points_at_the_stub() {
  case "$(cat "$OMARCHY_VPN_PRIVILEGED")" in
    *"/usr/bin/systemctl"*) fail "the copy still points at the real systemctl" ;;
  esac
  assert_contains "$(cat "$OMARCHY_VPN_PRIVILEGED")" "SYSTEMCTL=systemctl"
}

test_privileged_accepts_valid_calls() {
  priv start openvpn-client@Example_29 || fail "start was rejected"
  priv stop wg-quick@HomeNet     || fail "stop was rejected"
  # Digits, underscore, dot and hyphen in the instance name.
  priv start openvpn-client@a_b.c-d1    || fail "the instance name was rejected"
  # A trailing .service names the same unit and is allowed.
  priv stop wg-quick@x.service          || fail "the .service suffix was rejected"

  local log
  log="$(cat "$SANDBOX/systemctl.log")"
  assert_contains "$log" "start openvpn-client@Example_29"
  assert_contains "$log" "stop wg-quick@HomeNet"
  assert_contains "$log" "start openvpn-client@a_b.c-d1"
  assert_contains "$log" "stop wg-quick@x.service"
}

test_privileged_rejects_bad_action() {
  local a rc
  for a in restart enable START reload ""; do
    rc=0
    priv "$a" wg-quick@HomeNet >/dev/null 2>&1 || rc=$?
    assert_eq "$rc" "65"
  done
  assert_no_systemctl_call
}

test_privileged_rejects_bad_unit() {
  local u rc
  # Foreign prefix, missing instance, path separator, space, appended
  # command, options.
  #
  # "-fopenvpn-client@x" and "--root=/tmp/evil openvpn-client@x" cover the
  # '^' anchor on purpose: proved by mutation (^ removed from the
  # expression in share/omarchy-vpn-privileged), without it an unanchored
  # search pattern is used that finds the embedded unit name somewhere in
  # the input and wrongly accepts it -- "-fopenvpn-client@x" from position
  # 2, say. With ^ that is correctly rejected. No existing case covered
  # this before: "--now" and "-f" carry no '<prefix>@...' and fall through
  # unanchored as well.
  #
  # "openvpn-client@a b" (already present) covers the '$' anchor: without
  # $, the pattern matches only the prefix "openvpn-client@a" and wrongly
  # accepts, even though a "b" follows after the space. Likewise proved by
  # mutation.
  for u in "sshd" "openvpn-server@x" "wg-quick" "openvpn-client@" \
           "openvpn-client@../../x" "openvpn-client@a b" \
           "openvpn-client@x; id" "--now" "-f" "systemd-logind" \
           "-fopenvpn-client@x" "--root=/tmp/evil openvpn-client@x"; do
    rc=0
    priv start "$u" >/dev/null 2>&1 || rc=$?
    assert_eq "$rc" "66"
  done
  assert_no_systemctl_call
}

test_privileged_rejects_wrong_argument_count() {
  local rc
  rc=0; priv >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "64"
  rc=0; priv start >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "64"
  rc=0; priv start wg-quick@HomeNet --now >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "64"
  assert_no_systemctl_call
}

test_privileged_rejection_says_what_was_rejected() {
  local out
  out="$(priv restart wg-quick@HomeNet 2>&1)"
  assert_contains "$out" "restart"
  out="$(priv start sshd 2>&1)"
  assert_contains "$out" "sshd"
}

# ------------------------------------------------- omarchy-vpn-inspect
#
# Judges a pasted configuration, with no privileges. The rules are
# deliberately repeated in omarchy-vpn-import (task 2) -- a privileged
# program does not trust its caller. The agreement test there proves that
# both judge alike.
#
# The example configurations are invented. Never put the content of real
# files from ~/.ovpn or ~/wireguard into tests: they contain private
# keys.

ovpn_ok() {
  cat <<'CONF'
client
dev tun
proto tcp
remote 198.51.100.10 1194
cipher AES-128-CBC
<ca>
-----BEGIN CERTIFICATE-----
MIIExampleCA
-----END CERTIFICATE-----
</ca>
<cert>
-----BEGIN CERTIFICATE-----
MIIExampleCert
-----END CERTIFICATE-----
</cert>
<key>
-----BEGIN PRIVATE KEY-----
MIIExampleKey
-----END PRIVATE KEY-----
</key>
CONF
}

wg_ok() {
  cat <<'CONF'
[Interface]
PrivateKey = QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVowMTIzNDU2Nzg=
Address = 10.9.0.2/24

[Peer]
PublicKey = WlhZV1ZVVFNSUVBPTk1MS0pJSEdGRURDQkEwMTIzNDU2Nzg=
Endpoint = 198.51.100.20:51820
AllowedIPs = 10.9.0.0/24
CONF
}

# --------------------------------------------------------------------
# A stock of realistic provider configurations.
#
# Invented, but built after the pattern of real providers: two commercial
# services, a company gateway, .ovpn exports from pfSense and OPNsense, an
# old style (comp-lzo, ns-cert-type, fragment) and a new one (data-ciphers,
# tls-groups, dns server). They are the counter-proof to the allowlist: a
# list that has only been tested against attacks could simply be empty.
#
# EVERY one of these configurations was held against openvpn 2.7.6 and
# accepted by it (no 'Options error' line); only 'block-outside-dns' is
# unknown to openvpn on Linux -- there, as in reality, it sits behind
# 'setenv opt' and is therefore expressly non-fatal.
#
# Key material is placeholder text. Never put the content of real files
# from ~/.ovpn or ~/wireguard into tests: they contain private keys.

stock_names() {
  printf '%s\n' commercial_udp commercial_tcp443 company_gateway pfsense_udp \
                pfsense_conn opnsense old_23 new_26 multi_remote
}

# The embedded blocks that make each of these configurations
# self-contained -- placeholders, no real material.
stock_blocks() {
  local with="${1:-}"
  cat <<'CONF'
<ca>
-----BEGIN CERTIFICATE-----
MIIExampleCA
-----END CERTIFICATE-----
</ca>
<cert>
-----BEGIN CERTIFICATE-----
MIIExampleCert
-----END CERTIFICATE-----
</cert>
<key>
-----BEGIN PRIVATE KEY-----
MIIExampleKey
-----END PRIVATE KEY-----
</key>
CONF
  case "$with" in
    tls-auth)  printf '<tls-auth>\nMIIExampleTA\n</tls-auth>\n' ;;
    tls-crypt) printf '<tls-crypt>\nMIIExampleTC\n</tls-crypt>\n' ;;
  esac
}

stock_commercial_udp() {
  cat <<'CONF'
client
dev tun
proto udp
remote vpn-de-42.example-vpn.example 1194
resolv-retry infinite
remote-random
nobind
tun-mtu 1500
tun-mtu-extra 32
mssfix 1450
persist-key
persist-tun
ping 15
ping-restart 0
ping-timer-rem
reneg-sec 0
comp-lzo no
verify-x509-name vpn-de-42.example-vpn.example name
remote-cert-tls server
auth SHA512
verb 3
pull
fast-io
cipher AES-256-CBC
key-direction 1
CONF
  stock_blocks tls-auth
}

stock_commercial_tcp443() {
  cat <<'CONF'
client
dev tun
proto tcp-client
remote 198.51.100.7 443
remote 198.51.100.8 443
remote-random
resolv-retry infinite
nobind
persist-key
persist-tun
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
data-ciphers-fallback AES-256-CBC
auth SHA256
tls-client
tls-version-min 1.2
remote-cert-tls server
push-peer-info
setenv opt block-outside-dns
mute-replay-warnings
auth-nocache
explicit-exit-notify 0
verb 3
mute 20
CONF
  stock_blocks 
}

stock_company_gateway() {
  cat <<'CONF'
client
dev tun
dev-type tun
proto udp
remote gw.example-corp.example 1194
port 1194
nobind
persist-key
persist-tun
resolv-retry infinite
route-nopull
route 10.20.0.0 255.255.0.0
route 10.30.0.0 255.255.255.0 vpn_gateway 1
route-delay 2
dhcp-option DNS 10.20.0.53
dhcp-option DOMAIN example-corp.example
verify-x509-name "C=DE, O=Example Corp, CN=gw.example-corp.example" subject
remote-cert-tls server
remote-cert-eku "TLS Web Server Authentication"
x509-username-field CN
cipher AES-256-CBC
auth SHA256
tls-version-min 1.2
reneg-sec 3600
verb 3
CONF
  stock_blocks 
}

stock_pfsense_udp() {
  cat <<'CONF'
dev tun
persist-tun
persist-key
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
data-ciphers-fallback AES-256-CBC
auth SHA256
tls-client
client
resolv-retry infinite
remote 203.0.113.20 1194 udp4
nobind
verify-x509-name "pfsense-server" name
remote-cert-tls server
explicit-exit-notify
topology subnet
key-direction 1
verb 3
CONF
  stock_blocks tls-auth
}

stock_pfsense_conn() {
  cat <<'CONF'
dev tun
persist-tun
persist-key
data-ciphers AES-256-GCM:AES-128-GCM
auth SHA512
tls-client
client
resolv-retry infinite
nobind
remote-random
<connection>
remote 203.0.113.21 1194 tcp-client
connect-retry 5 30
connect-retry-max 3
connect-timeout 20
mssfix 1400
</connection>
<connection>
remote 203.0.113.22 443 tcp-client
connect-retry 5 30
nobind
</connection>
verify-x509-name "pfsense-server" name
remote-cert-tls server
topology subnet
verb 3
CONF
  stock_blocks 
}

stock_opnsense() {
  cat <<'CONF'
dev tun
persist-tun
persist-key
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
data-ciphers-fallback AES-256-CBC
auth SHA256
client
resolv-retry infinite
remote 192.0.2.44 1194 udp
lport 0
nobind
verify-x509-name "OPNsense-Server" name
remote-cert-tls server
tls-version-min 1.2
compress
topology subnet
redirect-gateway def1
route-metric 100
verb 1
CONF
  stock_blocks 
}

stock_old_23() {
  cat <<'CONF'
client
dev tun
proto udp
remote 192.0.2.60 1194
resolv-retry infinite
nobind
persist-key
persist-tun
ns-cert-type server
comp-lzo
comp-noadapt
tun-mtu 1500
mssfix 1400
fragment 1300
mtu-disc yes
cipher BF-CBC
auth SHA1
key-direction 1
route 192.168.77.0 255.255.255.0
redirect-private
float
keepalive 10 120
shaper 100000
verb 3
mute 10
CONF
  stock_blocks tls-auth
}

stock_new_26() {
  cat <<'CONF'
client
dev tun
proto udp
remote 198.51.100.90 1194
nobind
persist-key
persist-tun
resolv-retry infinite
data-ciphers AES-256-GCM:CHACHA20-POLY1305
tls-client
tls-version-min 1.3
tls-ciphersuites TLS_AES_256_GCM_SHA384
tls-groups X25519:secp521r1
tls-cert-profile preferred
remote-cert-tls server
allow-compression no
compat-mode 2.6.0
disable-dco
max-packet-size 1400
dns search-domains example.example
dns server 1 address 198.51.100.53
dns server 1 resolve-domains example.example
pull-filter ignore "redirect-gateway"
pull-filter accept "route "
ignore-unknown-option block-outside-dns
push-peer-info
verb 3
CONF
  stock_blocks tls-crypt
}

stock_multi_remote() {
  cat <<'CONF'
client
dev tun
proto udp
remote 203.0.113.30 1194 udp
remote 203.0.113.31 1195 udp
remote 203.0.113.32 443 tcp-client
proto-force udp
remote-random
remote-random-hostname
server-poll-timeout 8
connect-retry 2
connect-retry-max 5
resolv-retry 60
nobind
persist-key
persist-tun
persist-remote-ip
inactive 0
ping 10
ping-exit 60
tls-client
remote-cert-tls server
cipher AES-256-GCM
auth SHA256
reneg-bytes 0
reneg-pkts 0
replay-window 128 30
tran-window 3600
hand-window 60
tls-timeout 2
tcp-nodelay
sndbuf 0
rcvbuf 0
txqueuelen 1000
passtos
up-delay
route-table 200
route-gateway 10.8.0.1
route-ipv6 2001:db8::/32
route-noexec
setenv-safe UV_PLAT linux
setenv-safe CUSTOMER example
auth-retry nointeract
verb 4
CONF
  stock_blocks 
}

inspect() { "$BIN/omarchy-vpn-inspect"; }

test_inspect_accepts_selfcontained_openvpn() {
  local out
  out="$(ovpn_ok | inspect)"
  assert_eq "$(printf '%s' "$out" | jq -r '.ok')" "true"
  assert_eq "$(printf '%s' "$out" | jq -r '.kind')" "openvpn"
  assert_eq "$(printf '%s' "$out" | jq -r '.remote')" "198.51.100.10:1194"
  assert_eq "$(printf '%s' "$out" | jq -r '.embedded')" "true"
}

test_inspect_accepts_wireguard() {
  local out
  out="$(wg_ok | inspect)"
  assert_eq "$(printf '%s' "$out" | jq -r '.ok')" "true"
  assert_eq "$(printf '%s' "$out" | jq -r '.kind')" "wireguard"
  assert_eq "$(printf '%s' "$out" | jq -r '.remote')" "198.51.100.20:51820"
  assert_eq "$(printf '%s' "$out" | jq -r '.embedded')" "null"
}

# The .sha256 field is no longer used by the flow (the fingerprint
# comparison fell away with the file picker), but it remains the evidence
# for the normalization: here against sha256sum over the same content, and
# in test_add_written_file_matches_inspect_hash against the file that
# share/omarchy-vpn-import actually wrote.
test_inspect_hash_matches_sha256sum() {
  local out hash expected
  out="$(ovpn_ok | inspect)"
  hash="$(printf '%s' "$out" | jq -r '.sha256')"
  expected="$(ovpn_ok | sha256sum | cut -d' ' -f1)"
  assert_eq "$hash" "$expected"
}

test_inspect_rejects_directive_pointing_outside() {
  local d out
  for d in "ca ca.crt" "cert client.crt" "key client.key" "tls-auth ta.key 1" \
           "tls-crypt tc.key" "tls-crypt-v2 tc2.key" "dh dh2048.pem" \
           "pkcs12 client.p12" "secret static.key" "crl-verify crl.pem" \
           "config extra.conf"; do
    out="$( { ovpn_ok; printf '%s\n' "$d"; } | inspect )"
    assert_eq "$(printf '%s' "$out" | jq -r '.ok')" "false"
    assert_contains "$(printf '%s' "$out" | jq -r '.error')" "${d%% *}"
    [ "$(printf '%s' "$out" | jq -r '.line')" != "null" ] || \
      fail "line number missing for: $d"
  done
}

# Reproduced: key material outside a <ca>/<key> block (because the block
# markers were lost while copying, say) looks like an unexpected directive
# spelling -- even then the message must not contain the token in full,
# otherwise key material ends up in an error message.
test_inspect_truncates_long_token_in_error_message() {
  local long_token out error
  # A "+" at the end makes sure the line really counts as an unexpected
  # spelling -- a pure stream of letters would otherwise look like a
  # syntactically valid (merely unknown) option name and trigger no
  # violation at all. Base64 material regularly contains '+', '/' or '='
  # -- exactly as in the reproduced find.
  long_token="$(printf 'A%.0s' {1..199})+"
  out="$( { ovpn_ok; printf '%s\n' "$long_token"; } | inspect )"
  assert_eq "$(printf '%s' "$out" | jq -r '.ok')" "false"
  error="$(printf '%s' "$out" | jq -r '.error')"
  case "$error" in
    *"$long_token"*) fail "the message contains the full token" "$error" ;;
  esac
  assert_contains "$error" "..."
}

# auth-user-pass and askpass are rejected even WITHOUT an argument: with no
# file OpenVPN asks interactively, and a systemd unit has nobody to ask.
test_inspect_rejects_credentials_with_and_without_argument() {
  local d out
  for d in "auth-user-pass" "auth-user-pass credentials.txt" "askpass" "askpass pw.txt"; do
    out="$( { ovpn_ok; printf '%s\n' "$d"; } | inspect )"
    assert_eq "$(printf '%s' "$out" | jq -r '.ok')" "false"
    assert_contains "$(printf '%s' "$out" | jq -r '.error')" "Credentials"
  done
}

test_inspect_rejects_code_executing_directives() {
  local d out
  for d in "up /tmp/evil.sh" "down /tmp/evil.sh" "up-restart" \
           "route-up /tmp/x" "route-pre-down /tmp/x" "ipchange /tmp/x" \
           "client-connect /tmp/x" "client-disconnect /tmp/x" \
           "learn-address /tmp/x" "tls-verify /tmp/x" \
           "auth-user-pass-verify /tmp/x via-env" "plugin /tmp/x.so" \
           "script-security 2" \
           "--up /tmp/evil.sh" '"up" /tmp/evil.sh' "'up' /tmp/evil.sh" \
           "--script-security 2" 'u"p" /tmp/evil.sh'; do
    out="$( { ovpn_ok; printf '%s\n' "$d"; } | inspect )"
    assert_eq "$(printf '%s' "$out" | jq -r '.ok')" "false"
    assert_contains "$(printf '%s' "$out" | jq -r '.error')" "${d%% *}"
  done
}

# Every directive that four reviews of this project found to be an attack
# path, in ONE table -- so that it is noticed at once if a later rework of
# the allowlist lets one of them through again.
#
# Verified against openvpn 2.7.6: none of these lines produces
# "Unrecognized option", so openvpn accepts them. Proven effects, all as
# root (openvpn-client@.service has no User=): 'pkcs11-providers' loads a
# library and calls its constructor -- code as root WITHOUT
# script-security; 'log'/'log-append' overwrite an arbitrary file with log
# text, 'status' truncates it to 0 bytes, 'writepid' removes it;
# 'http-proxy-user-pass /etc/shadow' has openvpn read the file as root and
# send the beginning of it base64-encoded to the proxy; 'dev-node
# unix:<program>' starts the program ("OpenVPN will start the program").
test_inspect_rejects_every_attack_directive_from_four_reviews() {
  local d out
  for d in "up /tmp/x" "down /tmp/x" "up-restart" "route-up /tmp/x" \
           "route-pre-down /tmp/x" "ipchange /tmp/x" "client-connect /tmp/x" \
           "client-disconnect /tmp/x" "learn-address /tmp/x" \
           "tls-verify /tmp/x" "auth-user-pass-verify /tmp/x via-env" \
           "plugin /tmp/x.so" "script-security 2" "dns-updown /tmp/x" \
           "client-crresponse /tmp/x" "ca ca.crt" "cert c.crt" "key k.key" \
           "tls-auth ta.key 1" "tls-crypt tc.key" "tls-crypt-v2 tc2.key" \
           "dh dh.pem" "pkcs12 c.p12" "secret s.key" "crl-verify crl.pem" \
           "config extra.conf" "auth-user-pass" "askpass" "capath /etc/ssl" \
           "extra-certs /etc/x.pem" "http-proxy 203.0.113.9 8080 /etc/shadow" \
           "http-proxy-user-pass /etc/shadow" "socks-proxy 203.0.113.9 1080" \
           "management 127.0.0.1 7505" "log /etc/hostname" \
           "log-append /etc/hostname" "status /etc/hostname" \
           "writepid /etc/hostname" "genkey secret /etc/x" "tmp-dir /etc" \
           "chroot /etc" "cd /etc" "client-config-dir /etc" \
           "ifconfig-pool-persist /etc/x" "port-share 203.0.113.9 443" \
           "replay-persist /etc/hostname" "pkcs11-providers /tmp/evil.so" \
           "pkcs11-id-management" "show-pkcs11-ids /tmp/evil.so" \
           "tls-export-cert /etc" "iproute /tmp/ip.sh" \
           "dev-node unix:/tmp/prog" "auth-gen-token-secret /etc/tok"; do
    out="$( { ovpn_ok; printf '%s\n' "$d"; } | inspect )"
    [ "$(printf '%s' "$out" | jq -r '.ok')" = "false" ] || \
      fail "attack directive slipped through: $d"
    assert_contains "$(printf '%s' "$out" | jq -r '.error')" "${d%% *}"
    [ "$(printf '%s' "$out" | jq -r '.line')" != "null" ] || \
      fail "line number missing for: $d"
  done
}

# Review C2: <connection> blocks contain real directives, not key data --
# they must not be skipped as a block. Proved against openvpn 2.7.6:
# 'tls-auth <path>' inside the block loads the file ("Cannot pre-load
# keyfile"), and 'http-proxy <host> <port> <file>' is accepted as well. The
# allowlist applies inside the block just as it does above.
test_inspect_checks_directives_inside_connection_block() {
  local out
  out="$(printf 'client\ndev tun\nproto tcp-client\n<connection>\nremote 198.51.100.10 1194\ntls-auth /etc/hostname\n</connection>\n' | inspect)"
  assert_eq "$(printf '%s' "$out" | jq -r '.ok')" "false"
  assert_contains "$(printf '%s' "$out" | jq -r '.error')" "tls-auth"
  assert_eq "$(printf '%s' "$out" | jq -r '.line')" "6"
  out="$(printf 'client\ndev tun\nproto tcp-client\n<connection>\nremote 198.51.100.10 1194\nhttp-proxy 203.0.113.9 8080 /etc/shadow basic\n</connection>\n' | inspect)"
  assert_eq "$(printf '%s' "$out" | jq -r '.ok')" "false"
  assert_contains "$(printf '%s' "$out" | jq -r '.error')" "allowlist"
  out="$(printf 'client\ndev tun\nproto tcp-client\n<connection>\nremote 198.51.100.10 1194\nsetenv opt up /tmp/evil.sh\n</connection>\n' | inspect)"
  assert_eq "$(printf '%s' "$out" | jq -r '.ok')" "false"
}

# Counter-check to C2: an ordinary <connection> block is entirely
# legitimate and must pass -- including a configuration whose only remote
# sits INSIDE the block (the kind detection has to find it there).
# 'http-proxy' stood here until the switch to the allowlist; it is rejected
# now (see test_inspect_rejects_proxy_directives), and the block is filled
# with 'mssfix' instead.
test_inspect_accepts_legitimate_connection_block() {
  local out
  out="$(printf 'client\ndev tun\nproto tcp-client\n<connection>\nremote 198.51.100.10 1194 tcp\nconnect-retry 5\nnobind\n</connection>\n<connection>\nremote 198.51.100.11 443 tcp\nmssfix 1400\n</connection>\n' | inspect)"
  assert_eq "$(printf '%s' "$out" | jq -r '.ok')" "true"
  assert_eq "$(printf '%s' "$out" | jq -r '.kind')" "openvpn"
  assert_eq "$(printf '%s' "$out" | jq -r '.remote')" "198.51.100.10:1194"
}

# Review I1: the kind detection is the switch BEFORE the security check.
# If "[Interface]" stood anywhere in the text -- hidden inside a <ca> block
# as well -- the file counted as WireGuard and check_openvpn never ran:
# 'script-security 2' plus 'up ...' got through.
test_inspect_ignores_interface_marker_inside_embedded_block() {
  local out
  out="$(printf 'client\ndev tun\nproto udp\nremote 198.51.100.10 1194\nscript-security 2\nup /tmp/evil.sh\n<ca>\n[Interface]\nMIIExampleCA\n</ca>\n' | inspect)"
  assert_eq "$(printf '%s' "$out" | jq -r '.kind')" "openvpn"
  assert_eq "$(printf '%s' "$out" | jq -r '.ok')" "false"
  assert_contains "$(printf '%s' "$out" | jq -r '.error')" "script-security"
}

# Counter-check to I1: at the top level "[Interface]" remains the WireGuard
# marker -- the fix must not break the detection.
test_inspect_still_detects_wireguard_at_top_level() {
  local out
  out="$(wg_ok | inspect)"
  assert_eq "$(printf '%s' "$out" | jq -r '.kind')" "wireguard"
  assert_eq "$(printf '%s' "$out" | jq -r '.ok')" "true"
}

# The normalization of '--' and quotes keeps the check in line with what
# openvpn itself accepts: '--verb', '"verb"' and "'verb'" are the same as
# 'verb' to openvpn (verified against 2.7.6).
#
# Its role TURNED AROUND with the allowlist. Under the blocklist it
# prevented a bypass ('--up' was not in the table verbatim); now it
# prevents a WRONG REJECTION -- without it '--verb' would not be on the
# list and a valid configuration would fail. That is exactly what the first
# loop aims at: take the normalization out and it turns red.
test_inspect_normalization_matches_what_openvpn_accepts() {
  local d out
  for d in "--verb 3" '"verb" 3' "'verb' 3" "--persist-tun" '"nobind"'; do
    out="$( { ovpn_ok; printf '%s\n' "$d"; } | inspect )"
    [ "$(printf '%s' "$out" | jq -r '.ok')" = "true" ] || \
      fail "valid spelling rejected: $d" \
           "$(printf '%s' "$out" | jq -r '.error')"
  done
  for d in "--up /tmp/evil.sh" '"up" /tmp/evil.sh' "'up' /tmp/evil.sh" \
           "--script-security 2" "--ca ca.crt" '"status" /etc/hostname' \
           "--dns-updown /tmp/evil.sh"; do
    out="$( { ovpn_ok; printf '%s\n' "$d"; } | inspect )"
    assert_eq "$(printf '%s' "$out" | jq -r '.ok')" "false"
  done
  # And the safety net stays for what it is there for.
  out="$( { ovpn_ok; printf '%s\n' 'u"p" /tmp/evil.sh'; } | inspect )"
  assert_contains "$(printf '%s' "$out" | jq -r '.error')" "Unexpected directive spelling"
}

# up-delay and up-restart are different things: up-delay is harmless and
# has to pass, otherwise the check rejects valid configurations.
test_inspect_accepts_harmless_lookalike_directives() {
  local out
  out="$( { ovpn_ok; printf 'up-delay\n'; } | inspect )"
  assert_eq "$(printf '%s' "$out" | jq -r '.ok')" "true"
}

# Key material inside embedded blocks must not be read as a directive -- a
# base64 line that happens to start with "up" is not one.
test_inspect_ignores_lines_inside_embedded_blocks() {
  local out
  out="$( { printf 'client\ndev tun\nremote 198.51.100.10 1194\n<ca>\nup /tmp/evil.sh\nscript-security 2\n</ca>\n'; } | inspect )"
  assert_eq "$(printf '%s' "$out" | jq -r '.ok')" "true"
}

# Shows the gap through which the check could be bypassed: if the block
# stays open, every following line used to be skipped -- a code-executing
# directive included.
test_inspect_rejects_unclosed_embedded_block() {
  local out
  out="$( printf 'client\nremote 198.51.100.10 1194\n<ca>\nMIIExample\nup /tmp/evil.sh\n' | inspect )"
  assert_eq "$(printf '%s' "$out" | jq -r '.ok')" "false"
}

test_inspect_sees_closing_marker_with_trailing_text() {
  local out
  out="$( printf 'client\nremote 198.51.100.10 1194\n<ca>\nMIIExample\n</ca> trailing\nup /tmp/evil.sh\n' | inspect )"
  assert_eq "$(printf '%s' "$out" | jq -r '.ok')" "false"
  assert_contains "$(printf '%s' "$out" | jq -r '.error')" "up"
}

test_inspect_rejects_wireguard_hooks() {
  local d out
  for d in "PostUp = /tmp/evil.sh" "PreUp = /tmp/evil.sh" \
           "PostDown = /tmp/evil.sh" "PreDown = /tmp/evil.sh" \
           "postup = /tmp/evil.sh"; do
    out="$( { wg_ok; printf '%s\n' "$d"; } | inspect )"
    assert_eq "$(printf '%s' "$out" | jq -r '.ok')" "false"
  done
}

test_inspect_rejects_empty_input() {
  local out
  out="$(printf '' | inspect)"
  assert_eq "$(printf '%s' "$out" | jq -r '.ok')" "false"
  assert_contains "$(printf '%s' "$out" | jq -r '.error')" "empty"
}

test_inspect_rejects_unrecognizable_input() {
  local out
  out="$(printf 'Hello world\nsomething\n' | inspect)"
  assert_eq "$(printf '%s' "$out" | jq -r '.ok')" "false"
  assert_contains "$(printf '%s' "$out" | jq -r '.error')" "recognized"
}

# Valid JSON on EVERY path -- the user interface must never have to
# guess.
test_inspect_always_emits_valid_json() {
  local input
  for input in "" "Hello" "$(ovpn_ok)" "$(wg_ok)"; do
    printf '%s' "$input" | inspect | jq -e 'type == "object" and has("ok")' >/dev/null \
      || fail "not a valid JSON object for input: ${input:0:20}"
  done
}

# The other direction of the allowlist. A list that has only been tested
# against attacks proves nothing -- an empty list would pass every attack
# probe. This test turns red as soon as a directive that a real provider
# configuration needs drops off the list.
test_inspect_accepts_realistic_provider_configs() {
  local name out
  for name in $(stock_names); do
    out="$("stock_$name" | inspect)"
    [ "$(printf '%s' "$out" | jq -r '.ok')" = "true" ] || \
      fail "existing configuration rejected: $name" \
           "$(printf '%s' "$out" | jq -r '.error')"
    assert_eq "$(printf '%s' "$out" | jq -r '.kind')" "openvpn"
  done
}

# The same statement once more, but directive by directive: the lower
# bound of the list. It comes from real configurations on this machine and
# from four reviews. One by one instead of only as part of a stock file, so
# that a failure NAMES the directive that dropped off the list.
test_inspect_accepts_every_directive_of_the_minimum_set() {
  local d out
  for d in "client" "dev tun" "proto udp" "remote 198.51.100.10 1194" \
           "cipher AES-256-CBC" "resolv-retry infinite" "nobind" \
           "persist-key" "persist-tun" "verb 3" "mute 20" "auth SHA512" \
           "tls-client" "remote-cert-tls server" \
           "data-ciphers AES-256-GCM:AES-128-GCM" \
           "data-ciphers-fallback AES-256-CBC" \
           "verify-x509-name gw.example.example name" \
           "pull-filter ignore redirect-gateway" "setenv-safe UV_PLAT linux" \
           "compress" "comp-lzo no" "x509-username-field CN" \
           "key-direction 1" "redirect-gateway def1" \
           "dhcp-option DNS 10.20.0.53" "reneg-sec 0" "ping 15" \
           "ping-restart 0" "tun-mtu 1500" "mssfix 1450" "float" \
           "explicit-exit-notify" "auth-nocache" "remote-random" \
           "tls-version-min 1.2" "ncp-disable" "topology subnet" \
           "route 10.20.0.0 255.255.0.0" "route-nopull"; do
    out="$( { printf 'client\ndev tun\nremote 198.51.100.10 1194\n'; printf '%s\n' "$d"; } | inspect )"
    [ "$(printf '%s' "$out" | jq -r '.ok')" = "true" ] || \
      fail "lower-bound directive rejected: $d" \
           "$(printf '%s' "$out" | jq -r '.error')"
  done
}

# The price of the allowlist, checked explicitly: harmless directives drop
# out along with the rest. What matters here is not the verdict but the
# MESSAGE -- it has to say that the directive is missing, not that it is
# "forbidden".
test_inspect_rejects_directives_that_are_merely_absent() {
  local d out error
  for d in "daemon" "engine dynamic" "providers legacy" "syslog vpn" \
           "nice 5" "echo hello" "mlock" "errors-to-stderr" \
           "single-session" "mode server" "preresolve" "multihome"; do
    out="$( { ovpn_ok; printf '%s\n' "$d"; } | inspect )"
    assert_eq "$(printf '%s' "$out" | jq -r '.ok')" "false"
    error="$(printf '%s' "$out" | jq -r '.error')"
    assert_contains "$error" "allowlist"
    assert_contains "$error" "${d%% *}"
    [ "$(printf '%s' "$out" | jq -r '.line')" != "null" ] || \
      fail "line number missing for: $d"
  done
}

# The message is part of the spec, not decoration: line number, directive,
# "not on the list" (not "forbidden") and the way around it.
test_inspect_rejection_message_names_line_directive_and_the_way_around() {
  local out error
  out="$(printf 'client\ndev tun\nremote 198.51.100.10 1194\ndaemon\n' | inspect)"
  error="$(printf '%s' "$out" | jq -r '.error')"
  assert_eq "$(printf '%s' "$out" | jq -r '.ok')" "false"
  assert_eq "$(printf '%s' "$out" | jq -r '.line')" "4"
  assert_contains "$error" "daemon"
  assert_contains "$error" "allowlist"
  assert_contains "$error" "/etc/openvpn/client/"
  case "$error" in
    *forbidden*) fail "the message calls the directive 'forbidden'" "$error" ;;
  esac
}

# 'setenv opt <directive>' is NOT a variable assignment but a prefix:
# openvpn strikes the two words and processes the rest quite normally.
# Proved against 2.7.6 -- 'setenv opt up /tmp/x' fails with "--up script
# fails with '/tmp/x'", word for word the same as 'up /tmp/x'. Before this
# round that got through: 'setenv' was unchecked and thus a master key for
# every directive that is not on the list.
test_inspect_rejects_setenv_opt_prefix() {
  local d out
  for d in "setenv opt up /tmp/evil.sh" "setenv opt script-security 2" \
           "setenv opt ca /etc/shadow" "setenv opt plugin /tmp/x.so" \
           "setenv opt dev-node unix:/tmp/prog" \
           'setenv opt "up" /tmp/evil.sh' "setenv OPT up /tmp/evil.sh" \
           "setenv opt"; do
    out="$( { ovpn_ok; printf '%s\n' "$d"; } | inspect )"
    [ "$(printf '%s' "$out" | jq -r '.ok')" = "false" ] || \
      fail "setenv prefixing slipped through: $d"
  done
  # This block used to guard the opposite: it insisted that a plain
  # 'setenv NAME value' keep working, on the reasoning that striking
  # 'setenv' entirely would be the lazy answer to the prefix finding. The
  # second review round showed the reasoning was wrong. A bare 'setenv' sets
  # ANY variable for a root openvpn process -- LD_PRELOAD included -- so
  # striking it was not the lazy answer but the correct one, and the
  # counter-check was protecting the hole.
  for d in "setenv FORWARD_COMPATIBLE 1" "setenv UV_PLAT linux" \
           "setenv LD_PRELOAD /tmp/x"; do
    out="$( { ovpn_ok; printf '%s\n' "$d"; } | inspect )"
    [ "$(printf '%s' "$out" | jq -r '.ok')" = "false" ] || \
      fail "a bare setenv assignment was accepted: $d"
  done
  # What must keep working: the prefix form commercial providers ship -- it
  # passes on the strength of the directive behind it, not of 'setenv' --
  # and setenv-safe, which openvpn prefixes with OPENVPN_ so it cannot name
  # a loader variable.
  for d in "setenv opt block-outside-dns" "setenv-safe CUSTOMER example"; do
    out="$( { ovpn_ok; printf '%s\n' "$d"; } | inspect )"
    [ "$(printf '%s' "$out" | jq -r '.ok')" = "true" ] || \
      fail "valid setenv line rejected: $d" \
           "$(printf '%s' "$out" | jq -r '.error')"
  done
}

# Before the switch, a 200-character stream of letters was a syntactically
# valid, merely unknown option name -- and was ACCEPTED. It is rejected
# now, so a NEW path carries the message. That path must not print key
# material either.
test_inspect_truncates_long_absent_directive_in_error_message() {
  local long_token out error
  long_token="$(printf 'a%.0s' {1..200})"
  out="$( { ovpn_ok; printf '%s xyz\n' "$long_token"; } | inspect )"
  assert_eq "$(printf '%s' "$out" | jq -r '.ok')" "false"
  error="$(printf '%s' "$out" | jq -r '.error')"
  case "$error" in
    *"$long_token"*) fail "the message contains the full token" "$error" ;;
  esac
  assert_contains "$error" "..."
}

# A proxy is no longer on the list -- in any form. The earlier positional
# check ("the first two arguments are the remote and the port") was an
# assumption about openvpn's argument order, and
# 'http-proxy-user-pass <file>' walked past it in two lines: openvpn reads
# the file as root and sends the beginning of it to the proxy.
test_inspect_rejects_proxy_directives() {
  local d out error
  for d in "http-proxy 10.0.0.1 3128" \
           "http-proxy 203.0.113.9 8080 /etc/shadow basic" \
           "http-proxy-user-pass /etc/shadow" \
           "http-proxy-option AUTH_METHOD none" "http-proxy-retry" \
           "http-proxy-timeout 20" "socks-proxy 10.0.0.1" \
           "socks-proxy 10.0.0.1 1080 /etc/shadow" "socks-proxy-retry"; do
    out="$( { ovpn_ok; printf '%s\n' "$d"; } | inspect )"
    assert_eq "$(printf '%s' "$out" | jq -r '.ok')" "false"
    error="$(printf '%s' "$out" | jq -r '.error')"
    assert_contains "$error" "allowlist"
    assert_contains "$error" "${d%% *}"
  done
}

# Review Critical: the marker check ran BEFORE the indentation was
# stripped, while openvpn strips first. A CLOSING marker indented with a
# tab or spaces therefore closed the block for openvpn but not for us --
# everything after it counted as block content to the check and was
# silently skipped. The "never closed" fallback did not bite as soon as a
# normal marker followed at some point; an ordinary <cert> block was
# enough.
#
# Proved against openvpn 2.7.6: the file below runs there into
# "Options error: --up script fails with '/tmp/doesnotexist'" -- the line
# is evaluated as a top-level directive. inspect reported ok:true and
# import wrote the file with exit 0.
test_inspect_sees_indented_closing_marker() {
  local indent out
  for indent in "	" " " "  " "	 "; do
    out="$(printf 'client\ndev tun\nremote 198.51.100.10 1194\n<ca>\nMIIExampleCA\n%s</ca>\nup /tmp/evil.sh\n<cert>\nMIIExampleCert\n</cert>\n' "$indent" | inspect)"
    [ "$(printf '%s' "$out" | jq -r '.ok')" = "false" ] || \
      fail "indented closing marker did not close the block: [$indent]"
    assert_contains "$(printf '%s' "$out" | jq -r '.error')" "up"
    assert_eq "$(printf '%s' "$out" | jq -r '.line')" "7"
  done
}

# The counter-check, and the second half of the same finding: openvpn
# accepts an indented OPENING marker (verified: "  <ca>" and "	<ca>" open
# the block). Before the fix our check wrongly rejected it with
# "Unexpected directive spelling" -- the indentation was stripped only
# after the marker check, so the line counted as a directive.
test_inspect_accepts_indented_opening_marker() {
  local indent out
  for indent in "	" " " "   "; do
    out="$(printf 'client\ndev tun\nremote 198.51.100.10 1194\n%s<ca>\nMIIExampleCA\n%s</ca>\n' "$indent" "$indent" | inspect)"
    [ "$(printf '%s' "$out" | jq -r '.ok')" = "true" ] || \
      fail "indented opening marker rejected: [$indent]" \
           "$(printf '%s' "$out" | jq -r '.error')"
  done
  # And the block content really is skipped in the process -- otherwise the
  # test above would be green even if the marker did not count as a marker
  # at all and the content just happened to be harmless.
  out="$(printf 'client\ndev tun\nremote 198.51.100.10 1194\n\t<ca>\nup /tmp/evil.sh\n\t</ca>\n' | inspect)"
  assert_eq "$(printf '%s' "$out" | jq -r '.ok')" "true"
}

# This test used to be called
# test_inspect_sees_opening_marker_with_trailing_text and expected ok:true
# -- on the grounds that openvpn rejects "<ca> trailing" itself. That is
# exactly the class of assumption that has broken five times in this
# project: a claim about what openvpn does, made BEFORE comparing. The
# assumption does hold (verified against 2.7.6: "Unrecognized option ...
# <ca>", fatal) -- but HOLDING it costs nothing: an opening marker counts
# only in the shape openvpn accepts, namely exactly "<tag>" with nothing
# trailing. Everything else falls into the directive check and is rejected
# there.
test_inspect_rejects_opening_marker_with_trailing_text() {
  local d out
  for d in "<ca> trailing" "<ca> trailing>" "<ca x>" "x<ca>"; do
    out="$(printf 'client\ndev tun\nremote 198.51.100.10 1194\n%s\nup /tmp/evil.sh\n</ca>\n' "$d" | inspect)"
    [ "$(printf '%s' "$out" | jq -r '.ok')" = "false" ] || \
      fail "not a real marker, yet taken as the start of a block: $d"
    assert_eq "$(printf '%s' "$out" | jq -r '.line')" "4"
  done
  # With the CLOSING marker openvpn is demonstrably generous:
  # "</ca> trailing" and "</ca>x" close the block (verified). So we close
  # there too -- otherwise we would skip lines that openvpn evaluates.
  for d in "</ca> trailing" "</ca>x"; do
    out="$(printf 'client\ndev tun\nremote 198.51.100.10 1194\n<ca>\nMIIExampleCA\n%s\nup /tmp/evil.sh\n' "$d" | inspect)"
    assert_eq "$(printf '%s' "$out" | jq -r '.ok')" "false"
    assert_contains "$(printf '%s' "$out" | jq -r '.error')" "up"
  done
}

# And the disguise once more over the new path: a line that is no longer a
# marker must not confuse the KIND detection. No matter whether the file
# then counts as OpenVPN or as WireGuard -- a hook must not get through.
test_inspect_rejects_hook_behind_a_fake_marker() {
  local out
  out="$(printf 'client\ndev tun\nremote 198.51.100.10 1194\n<ca> trailing\n[Interface]\nPostUp = /tmp/evil.sh\n</ca>\n' | inspect)"
  assert_eq "$(printf '%s' "$out" | jq -r '.ok')" "false"
}

# Review Important 1: EVERY <tag> block used to be skipped, not just key
# material. But openvpn can inline more than keys -- the manual page names
# 15 options (section INLINE FILE SUPPORT), and 2.7.6 additionally accepts
# '<secret>'. Among them are three that would have carried something SECRET
# in the clear into /etc/openvpn/client/:
#
#   <auth-user-pass>user/password</auth-user-pass>           -- password
#   <http-proxy-user-pass>...</http-proxy-user-pass>         -- password
#   <auth-gen-token-secret>...</auth-gen-token-secret>       -- key
#
# openvpn 2.7.6 accepts all three (verified: the configuration runs, or at
# least fails on something else first). The same thing written as a
# DIRECTIVE was rejected -- two spellings, two verdicts.
test_inspect_rejects_inline_blocks_that_are_not_key_material() {
  local t out error
  for t in auth-user-pass http-proxy-user-pass auth-gen-token-secret secret \
           config log up plugin script-security dev-node management; do
    out="$(printf 'client\ndev tun\nremote 198.51.100.10 1194\n<%s>\nhushhush\n</%s>\n' "$t" "$t" | inspect)"
    [ "$(printf '%s' "$out" | jq -r '.ok')" = "false" ] || \
      fail "inline block slipped through: <$t>"
    error="$(printf '%s' "$out" | jq -r '.error')"
    assert_contains "$error" "$t"
    assert_eq "$(printf '%s' "$out" | jq -r '.line')" "4"
    # The content must not end up in the message in the process.
    case "$error" in *hushhush*) fail "the message contains the block content" "$error" ;; esac
  done
  # Credentials get the message that names them as a block too.
  out="$(printf 'client\ndev tun\nremote 198.51.100.10 1194\n<auth-user-pass>\nb\np\n</auth-user-pass>\n' | inspect)"
  assert_contains "$(printf '%s' "$out" | jq -r '.error')" "Credentials"
}

# Counter-check: the blocks a self-contained configuration REALLY needs
# must still be skipped -- content that looks like a directive included.
test_inspect_accepts_inline_key_material_blocks() {
  local t out
  for t in ca cert key dh extra-certs pkcs12 crl-verify tls-auth tls-crypt \
           tls-crypt-v2 peer-fingerprint verify-hash; do
    out="$(printf 'client\ndev tun\nremote 198.51.100.10 1194\n<%s>\nup /tmp/evil.sh\n</%s>\n' "$t" "$t" | inspect)"
    [ "$(printf '%s' "$out" | jq -r '.ok')" = "true" ] || \
      fail "key block rejected: <$t>" "$(printf '%s' "$out" | jq -r '.error')"
  done
}

# Review Important 3: 'user nobody' and 'group nobody' appear in OpenVPN's
# own example configuration and in many provider bundles. They read no
# file, start no program, open no channel and do not switch to server mode
# -- and they IMPROVE security (dropping privileges after the tunnel is
# up). It would have been the only case in which the allowlist excludes a
# hardening directive.
test_inspect_accepts_privilege_dropping_directives() {
  local d out
  for d in "user nobody" "group nobody" "user openvpn" "group network"; do
    out="$( { ovpn_ok; printf '%s\n' "$d"; } | inspect )"
    [ "$(printf '%s' "$out" | jq -r '.ok')" = "true" ] || \
      fail "privilege drop rejected: $d" "$(printf '%s' "$out" | jq -r '.error')"
  done
}

# The most frequent rejection must not end in a dead end: the credentials
# message names the way around too.
test_inspect_credentials_message_names_the_way_around() {
  local d out error
  for d in "auth-user-pass" "auth-user-pass credentials.txt" "askpass" \
           "static-challenge Code 1"; do
    out="$( { ovpn_ok; printf '%s\n' "$d"; } | inspect )"
    error="$(printf '%s' "$out" | jq -r '.error')"
    assert_eq "$(printf '%s' "$out" | jq -r '.ok')" "false"
    assert_contains "$error" "Credentials"
    assert_contains "$error" "/etc/openvpn/client/"
  done
}

# Regression cover over the WHOLE class, not over a selection.
#
# The reviewer put each of the unlisted directives ONTO the allowlist one
# at a time and ran the suite: for 122 out of 186 everything stayed green.
# No open hole -- but the cover was missing precisely over the class the
# blocklist had failed on three times ('engine', 'providers',
# 'cryptoapicert', 'pkcs11-id', 'down-pre', 'tls-crypt-v2-verify', the
# 'management-*' family, 'server', 'push*', 'ifconfig*').
#
# Instead of a longer selection, the complete complement stands here: all
# 186 directives of the openvpn 2.7.6 manual page that are NOT on the
# allowlist. If someone puts one of them on it, this test turns red and
# names it. Generated from the 297 headings of the manual page minus the
# allowlist.
#
# The name alone is enough as a payload: what is checked is the directive
# name, not its argument.
test_inspect_rejects_every_directive_that_is_not_on_the_allowlist() {
  local d out n=0
  for d in \
          allow-deprecated-insecure-static-crypto allow-nonadmin \
          allow-pull-fqdn allow-recursive-routing askpass \
          auth-gen-token auth-gen-token-secret auth-token \
          auth-token-user auth-user-pass auth-user-pass-optional \
          auth-user-pass-verify bcast-buffers bind-dev block-ipv6 ca \
          capath ccd-exclusive cd cert chroot client-cert-not-required \
          client-config-dir client-connect client-crresponse \
          client-disconnect client-nat client-to-client config \
          connect-freq connect-freq-initial crl-verify cryptoapicert \
          daemon dev-node dh dhcp-release dhcp-renew disable \
          dns-updown down down-pre duplicate-cn echo engine \
          errors-to-stderr extra-certs force-tls-key-material-export \
          genkey hash-size help http-proxy http-proxy-option \
          http-proxy-retry http-proxy-timeout http-proxy-user-pass \
          ifconfig ifconfig-ipv6 ifconfig-ipv6-pool ifconfig-ipv6-push \
          ifconfig-noexec ifconfig-nowarn ifconfig-pool \
          ifconfig-pool-linear ifconfig-pool-persist ifconfig-push \
          ip-win32 ipchange iproute iroute iroute-ipv6 key key-method \
          keying-material-exporter learn-address lladdr log log-append \
          machine-readable-output management management-client \
          management-client-auth management-client-group \
          management-client-pf management-client-user \
          management-external-cert management-external-key \
          management-forget-disconnect management-hold \
          management-log-cache management-query-passwords \
          management-query-proxy management-query-remote \
          management-signal management-up-down mark max-clients \
          max-routes max-routes-per-client mktun mlock mode mtu-test \
          multihome nice no-iv no-replay opt-verify override-username \
          pause-exit pkcs11-cert-private pkcs11-id \
          pkcs11-id-management pkcs11-pin-cache pkcs11-private-mode \
          pkcs11-protected-authentication pkcs11-providers pkcs12 \
          plugin port-share preresolve prng providers push push-remove \
          push-reset register-dns remap-usr1 replay-persist rmtun \
          route-method route-pre-down route-up script-security server \
          server-bridge server-ipv6 service session-timeout setcon \
          show-adapters show-ciphers show-digests show-engines \
          show-gateway show-groups show-net show-net-up \
          show-pkcs11-ids show-tls show-valid-subnets single-session \
          socket-flags socks-proxy socks-proxy-retry \
          stale-routes-check static-challenge status status-version \
          suppress-timestamps syslog tap-sleep tcp-queue-limit \
          test-crypto tls-auth tls-crypt tls-crypt-v2 \
          tls-crypt-v2-max-age tls-crypt-v2-verify tls-exit \
          tls-export-cert tls-server tls-verify tmp-dir up up-restart \
          use-prediction-resistance username-as-common-name \
          verify-client-cert vlan-accept vlan-pvid vlan-tagging \
          win-sys windows-driver writepid x509-track; do
    out="$( { ovpn_ok; printf '%s x\n' "$d"; } | inspect )"
    [ "$(printf '%s' "$out" | jq -r '.ok')" = "false" ] || \
      fail "unlisted directive slipped through: $d"
    n=$((n + 1))
  done
  # Counted along: if a line drops out of the table during a rework, it is
  # noticed here and not only at the next review.
  assert_eq "$n" "186"
}

# The other direction of the same, over the full list: 111 of the 297
# manual-page directives pass, plus 'ncp-ciphers' -- no longer a manual
# heading in 2.7.6, but still on the allowlist. That makes 112. Without
# this test the one above could be "satisfied" by emptying the allowlist.
test_inspect_accepts_exactly_the_directives_on_the_allowlist() {
  local d n=0
  for d in \
          allow-compression auth auth-nocache auth-retry bind \
          block-outside-dns cipher client comp-lzo comp-noadapt \
          compat-mode compress connect-retry connect-retry-max \
          connect-timeout data-ciphers data-ciphers-fallback dev \
          dev-type dhcp-option disable-dco disable-occ dns ecdh-curve \
          explicit-exit-notify fast-io float fragment group \
          hand-window ignore-unknown-option inactive keepalive \
          key-direction link-mtu local lport max-packet-size mssfix \
          mtu-disc mute mute-replay-warnings ncp-ciphers ncp-disable \
          nobind ns-cert-type passtos peer-fingerprint persist-key \
          persist-local-ip persist-remote-ip persist-tun ping \
          ping-exit ping-restart ping-timer-rem port proto proto-force \
          pull pull-filter push-peer-info rcvbuf redirect-gateway \
          redirect-private remote remote-cert-eku remote-cert-ku \
          remote-cert-tls remote-random remote-random-hostname \
          reneg-bytes reneg-pkts reneg-sec replay-window resolv-retry \
          route route-delay route-gateway route-ipv6 \
          route-ipv6-gateway route-metric route-noexec route-nopull \
          route-table rport server-poll-timeout setenv-safe \
          shaper sndbuf tcp-nodelay tls-cert-profile tls-cipher \
          tls-ciphersuites tls-client tls-groups tls-timeout \
          tls-version-max tls-version-min topology tran-window tun-mtu \
          tun-mtu-extra tun-mtu-max txqueuelen up-delay user verb \
          verify-hash verify-x509-name x509-username-field; do
    [ "$( { ovpn_ok; printf '%s x\n' "$d"; } | inspect | jq -r '.ok')" = "true" ] || \
      fail "listed directive rejected: $d"
    n=$((n + 1))
  done
  # 111 since the second review round: bare 'setenv' was struck. See
  # test_setenv_cannot_set_loader_variables for why.
  assert_eq "$n" "111"
}

# -------------------------------------------------- omarchy-vpn-import
#
# The second privileged program. It runs as root through pkexec and writes
# into /etc -- the checks here are the gate. Unlike the switching program,
# there is no argument restriction by polkit here: the action permits the
# call, the program decides about the content.
#
# What runs is the copy from $SANDBOX/priv, whose target directories point
# into the sandbox (see setup_sandbox).

imp() { "$OMARCHY_VPN_IMPORT" "$@"; }

assert_nothing_written() {
  local n
  n="$(find "$SANDBOX/etc" -type f 2>/dev/null | wc -l | tr -d ' ')"
  [ "$n" = "0" ] || fail "nothing should have been written" \
                         "found: $(find "$SANDBOX/etc" -type f)"
}

test_import_writes_openvpn_config() {
  ovpn_ok | imp add openvpn Office || fail "add was rejected"
  [ -f "$SANDBOX/etc/openvpn/client/Office.conf" ] || fail "file is missing"
  assert_eq "$(cat "$SANDBOX/etc/openvpn/client/Office.conf")" "$(ovpn_ok)"
  assert_eq "$(stat -c '%a' "$SANDBOX/etc/openvpn/client/Office.conf")" "600"
}

test_import_writes_wireguard_config() {
  wg_ok | imp add wireguard homenet || fail "add was rejected"
  [ -f "$SANDBOX/etc/wireguard/homenet.conf" ] || fail "file is missing"
  assert_eq "$(stat -c '%a' "$SANDBOX/etc/wireguard/homenet.conf")" "600"
}

# A configuration that differs from ovpn_ok by EXACTLY one harmless,
# allowed line. 'verb' is on the allowlist -- so the difference lies purely
# in the CONTENT, not in the question of whether the file passes the check.
# Without that, a test for 72 could also turn green when 71 was really what
# happened.
ovpn_ok_variant() { ovpn_ok; printf 'verb 4\n'; }

# A property of the target file from which EVERY write can be read off: the
# import writes via mktemp + mv, so a write inevitably changes the inode
# number -- and the modification time with it.
file_fingerprint() { stat -c '%i %y %s' "$1"; }

# A byte-identical existing file: nothing to do, success, NOTHING written.
# That is half (a) of the way out of the dead end -- without it the user
# could only reach an orphaned file in /etc through 'sudo rm'.
test_import_accepts_identical_existing_file() {
  local rc=0 target before after
  target="$SANDBOX/etc/openvpn/client/Office.conf"
  ovpn_ok | imp add openvpn Office || fail "the first add failed"
  before="$(file_fingerprint "$target")"
  ovpn_ok | imp add openvpn Office || rc=$?
  assert_eq "$rc" "0"
  after="$(file_fingerprint "$target")"
  # Inode AND modification time: had the import written, the inode alone
  # would already be a different one (mktemp creates anew, mv renames).
  assert_eq "$after" "$before"
  assert_eq "$(cat "$target")" "$(ovpn_ok)"
}

# The same for WireGuard -- the second kind runs through the same branch,
# but through a different check and into a different directory.
test_import_accepts_identical_existing_wireguard_file() {
  local rc=0 target before after
  target="$SANDBOX/etc/wireguard/homenet.conf"
  wg_ok | imp add wireguard homenet || fail "the first add failed"
  before="$(file_fingerprint "$target")"
  wg_ok | imp add wireguard homenet || rc=$?
  assert_eq "$rc" "0"
  assert_eq "$(file_fingerprint "$target")" "$before"
}

# Differing content: it stays at 72, and the existing file stays
# untouched. It is NEVER overwritten -- not even when there is no list
# entry for the file any more (this program does not know the list at all).
# The same directories hold the configurations placed there by hand, which
# never had an entry.
test_import_rejects_existing_name_with_other_content() {
  local rc=0 target before
  target="$SANDBOX/etc/openvpn/client/Office.conf"
  ovpn_ok | imp add openvpn Office || fail "the first add failed"
  before="$(file_fingerprint "$target")"
  ovpn_ok_variant | imp add openvpn Office >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "72"
  assert_eq "$(file_fingerprint "$target")" "$before"
  assert_eq "$(cat "$target")" "$(ovpn_ok)"
}

# The message for 72 pinned down by its four features: it says that the
# CONTENT is the reason, it says WHY the name can be taken (an earlier
# removal without the tick), and it names BOTH ways out. It used to read
# only "name already exists: <path>" -- correct, but without an
# explanation, and the user assumed the removal had settled the matter.
test_import_existing_name_message_explains_and_offers_both_ways_out() {
  local rc=0 err
  ovpn_ok | imp add openvpn Office || fail "the first add failed"
  err="$(ovpn_ok_variant | imp add openvpn Office 2>&1 >/dev/null)" || rc=$?
  assert_eq "$rc" "72"
  assert_contains "$err" "with different content"
  assert_contains "$err" "also delete the file"
  assert_contains "$err" "pick a different label"
  assert_contains "$err" "sudo rm $SANDBOX/etc/openvpn/client/Office.conf"
  # ONE LINE. bin/omarchy-vpn-add passes on only 'tail -n1' and Panel.qml
  # shows only the last line -- a second line would be lost unnoticed, and
  # it would be precisely the explanation.
  assert_eq "$(printf '%s' "$err" | wc -l | tr -d ' ')" "0"
}

# The ordering IS the security statement: the allowlist runs BEFORE the
# comparison. Here a byte-identical file is already in place -- the
# configuration must still fail the check (71), not be waved through as
# "identical, nothing to do" (0). Were the existence check back on top,
# "already exists" would be a way past the check.
test_import_checks_allowlist_before_comparing_with_existing_file() {
  local rc=0 payload target
  target="$SANDBOX/etc/openvpn/client/Office.conf"
  payload="$(ovpn_ok; printf 'up /tmp/evil\n')"
  # Placed by hand, not through the import -- which would reject it, that
  # being the point.
  printf '%s\n' "$payload" >"$target"
  # A precondition: it really has to be byte-identical, otherwise the test
  # only checks that 71 comes before 72.
  printf '%s\n' "$payload" | cmp -s - "$target" \
    || fail "the stored file is not byte-identical -- the test checks nothing"
  printf '%s\n' "$payload" | imp add openvpn Office >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "71"
}

# The mirror image of
# test_import_checks_allowlist_before_comparing_with_existing_file for
# WireGuard: the same security statement (allowlist before comparison), but
# through check_wireguard instead of check_openvpn and into a different
# directory. Without this test, "identical file" was covered for both
# kinds, but the security-relevant half, "ordering", only for OpenVPN.
# Mutation probe: pull the existence check back in front of the allowlist
# -- this test AND its OpenVPN counterpart above must both turn red (rc 0
# instead of 71).
test_import_checks_allowlist_before_comparing_with_existing_wireguard_file() {
  local rc=0 payload target
  target="$SANDBOX/etc/wireguard/home.conf"
  payload="$(wg_ok; printf 'PostUp = /tmp/evil.sh\n')"
  # Placed by hand, not through the import -- which would reject it, that
  # being the point.
  printf '%s\n' "$payload" >"$target"
  # A precondition: it really has to be byte-identical, otherwise the test
  # only checks that 71 comes before 72.
  printf '%s\n' "$payload" | cmp -s - "$target" \
    || fail "the stored file is not byte-identical -- the test checks nothing"
  printf '%s\n' "$payload" | imp add wireguard home >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "71"
}

# The target is a directory instead of a file: no regular file, no content
# to compare. It must still lead to 72, but the message must NOT speak of
# "different content" -- there is none here at all.
# Mutation probe: replace [ -f ] with [ -e ] again -- 'cmp' then compares
# against a directory, reports a read error instead of equality, the exit
# code happens to stay 72 but comes with the misleading "different content"
# message that this test holds on to. It turns red.
test_import_rejects_directory_at_target() {
  local rc=0 target before out
  target="$SANDBOX/etc/openvpn/client/Office.conf"
  mkdir -p "$target"
  before="$(file_fingerprint "$target")"
  out="$(ovpn_ok | imp add openvpn Office 2>&1 >/dev/null)" || rc=$?
  assert_eq "$rc" "72"
  assert_eq "$(file_fingerprint "$target")" "$before"
  [ -d "$target" ] || fail "the directory should have been left in place"
  case "$out" in
    *"different content"*) fail "the message claims a content comparison that never happened: $out" ;;
  esac
  assert_contains "$out" "$target"
}

# The target is a FIFO: with the old [ -e ], 'cmp' hangs indefinitely when
# it tries to read from it (measured with 'timeout 4': rc 124) -- and
# bin/omarchy-vpn-add puts no 'timeout' of its own around the pkexec call,
# so the widget would sit there until someone kills the root process by
# hand. Hence the direct call under 'timeout' here instead of through
# 'imp': a reintroduced bug should make THIS test fail (rc 124), not stall
# the whole suite.
# Mutation probe: replace [ -f ] with [ -e ] again -- the test hangs until
# the 'timeout' expires and turns red with rc 124 instead of 72.
test_import_rejects_fifo_at_target() {
  local rc=0 target before out
  target="$SANDBOX/etc/openvpn/client/Office.conf"
  mkfifo "$target"
  before="$(file_fingerprint "$target")"
  out="$(ovpn_ok | timeout 4 "$OMARCHY_VPN_IMPORT" add openvpn Office 2>&1 >/dev/null)" || rc=$?
  assert_eq "$rc" "72"
  assert_eq "$(file_fingerprint "$target")" "$before"
  [ -p "$target" ] || fail "the FIFO should have been left in place"
  case "$out" in
    *"different content"*) fail "the message claims a content comparison that never happened: $out" ;;
  esac
}

# The target is a symlink to a byte-identical file elsewhere: with the old
# check ([ -e ], then cmp) the result would have been 0 -- the symlink
# would stay, the list entry would come into being, and it points at a file
# whose content could be changed outside this program and without
# authenticating again. That is why EVERY symlink onto something existing
# is rejected, regardless of what lies behind it -- see the comment in the
# script for the decision.
# Mutation probe: remove the separate [ -L ] check in the script -- this
# test turns red (rc 0 instead of 72).
test_import_rejects_symlink_to_identical_file() {
  local rc=0 target elsewhere before out
  target="$SANDBOX/etc/openvpn/client/Office.conf"
  elsewhere="$SANDBOX/elsewhere.conf"
  ovpn_ok >"$elsewhere"
  ln -s "$elsewhere" "$target"
  before="$(file_fingerprint "$elsewhere")"
  out="$(ovpn_ok | imp add openvpn Office 2>&1 >/dev/null)" || rc=$?
  assert_eq "$rc" "72"
  [ -L "$target" ] || fail "the symlink should have been left in place"
  assert_eq "$(readlink "$target")" "$elsewhere"
  assert_eq "$(file_fingerprint "$elsewhere")" "$before"
  assert_contains "$out" "symlink"
}

test_import_rejects_bad_name() {
  local n rc
  for n in "a/b" "a b" "-evil" "." ".." "" "a;id" "a\$(id)" \
           "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; do
    rc=0
    ovpn_ok | imp add openvpn "$n" >/dev/null 2>&1 || rc=$?
    assert_eq "$rc" "70"
  done
  assert_nothing_written
}

# wg-quick turns the name into an interface name and itself enforces at
# most 15 characters. A longer name could be created but never started.
test_import_rejects_long_wireguard_name() {
  local rc=0
  wg_ok | imp add wireguard "sixteencharacter" >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "70"
  # With OpenVPN the same name is fine.
  ovpn_ok | imp add openvpn "sixteencharacter" || fail "OpenVPN would have accepted it"
}

test_import_rejects_bad_kind_and_argument_count() {
  local rc
  rc=0; ovpn_ok | imp add ipsec Office >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "64"
  # Too few.
  rc=0; ovpn_ok | imp add openvpn >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "64"
  # Too many: since the fingerprint fell away, 'add' takes EXACTLY three
  # arguments. A fourth means a caller still using the old shape -- that
  # has to be noticed and must not pass in silence.
  rc=0; ovpn_ok | imp add openvpn Office extraarg >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "64"
  rc=0; imp >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "64"
  rc=0; ovpn_ok | imp delete openvpn Office >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "64"
  assert_nothing_written
}

test_import_rejects_empty_and_unrecognizable_input() {
  local rc
  rc=0; printf '' | imp add openvpn Office >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "73"
  rc=0; printf 'Hello world\n' | imp add openvpn Office >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "73"
  assert_nothing_written
}

# The privileged program checks the rules ITSELF, not in reliance on
# omarchy-vpn-inspect: the caller could be somebody else.
test_import_rejects_non_selfcontained_config() {
  local d rc payload
  for d in "ca ca.crt" "key client.key" "config extra.conf" "auth-user-pass" \
           "up /tmp/evil.sh" "script-security 2" "plugin /tmp/x.so" \
           "--up /tmp/evil.sh" '"up" /tmp/evil.sh' "'up' /tmp/evil.sh" \
           "--script-security 2" 'u"p" /tmp/evil.sh'; do
    payload="$( { ovpn_ok; printf '%s\n' "$d"; } )"
    rc=0
    printf '%s\n' "$payload" | imp add openvpn Office >/dev/null 2>&1 || rc=$?
    assert_eq "$rc" "71"
  done
  for d in "PostUp = /tmp/evil.sh" "PreDown = /tmp/evil.sh"; do
    payload="$( { wg_ok; printf '%s\n' "$d"; } )"
    rc=0
    printf '%s\n' "$payload" | imp add wireguard home >/dev/null 2>&1 || rc=$?
    assert_eq "$rc" "71"
  done
  assert_nothing_written
}

# The bypass found in the unprivileged checker must be closed here all the
# more: here the file lands in /etc and later runs as root.
test_import_rejects_block_escape() {
  local payload rc
  # Block never closed, code-executing directive behind it.
  payload="$(printf 'client\nremote 198.51.100.10 1194\n<ca>\nMIIExample\nup /tmp/evil.sh\n')"
  rc=0
  printf '%s\n' "$payload" | imp add openvpn Escape1 >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "71"
  # Closing marker with trailing text.
  payload="$(printf 'client\nremote 198.51.100.10 1194\n<ca>\nMIIExample\n</ca> trailing\nup /tmp/evil.sh\n')"
  rc=0
  printf '%s\n' "$payload" | imp add openvpn Escape2 >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "71"
  # Closing marker with trailing text, FOLLOWED by a clean "</ca>".
  # Without this second case, mutation probe E0 stays green unnoticed: if
  # the marker check only recognizes the whole line (instead of the first
  # character), "</ca> trailing" falls through both case branches, the
  # following "up" is silently skipped as "still inside the block" -- and
  # the cleanly written "</ca>" that comes later does close the block after
  # all, BEFORE end of file. The "never closed" fallback that would
  # otherwise catch it does NOT bite then (the block counts as closed), and
  # the configuration is wrongly accepted. Only this second closing marker
  # uncovers that; the case above on its own is already caught by the
  # "never closed" fallback -- regardless of whether the marker check
  # itself was reworked.
  payload="$(printf 'client\nremote 198.51.100.10 1194\n<ca>\nMIIExample\n</ca> trailing\nup /tmp/evil.sh\n</ca>\n')"
  rc=0
  printf '%s\n' "$payload" | imp add openvpn Escape2b >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "71"
  assert_nothing_written
}

# The mirror image of the inspect test, here directly against the
# privileged program: it does not trust its caller, so it has to be checked
# on its own. And every rejection proves that NOTHING was written.
test_import_rejects_every_attack_directive_from_four_reviews() {
  local d rc payload
  for d in "up /tmp/x" "down /tmp/x" "up-restart" "route-up /tmp/x" \
           "route-pre-down /tmp/x" "ipchange /tmp/x" "client-connect /tmp/x" \
           "client-disconnect /tmp/x" "learn-address /tmp/x" \
           "tls-verify /tmp/x" "auth-user-pass-verify /tmp/x via-env" \
           "plugin /tmp/x.so" "script-security 2" "dns-updown /tmp/x" \
           "client-crresponse /tmp/x" "ca ca.crt" "cert c.crt" "key k.key" \
           "tls-auth ta.key 1" "tls-crypt tc.key" "tls-crypt-v2 tc2.key" \
           "dh dh.pem" "pkcs12 c.p12" "secret s.key" "crl-verify crl.pem" \
           "config extra.conf" "auth-user-pass" "askpass" "capath /etc/ssl" \
           "extra-certs /etc/x.pem" "http-proxy 203.0.113.9 8080 /etc/shadow" \
           "http-proxy-user-pass /etc/shadow" "socks-proxy 203.0.113.9 1080" \
           "management 127.0.0.1 7505" "log /etc/hostname" \
           "log-append /etc/hostname" "status /etc/hostname" \
           "writepid /etc/hostname" "genkey secret /etc/x" "tmp-dir /etc" \
           "chroot /etc" "cd /etc" "client-config-dir /etc" \
           "ifconfig-pool-persist /etc/x" "port-share 203.0.113.9 443" \
           "replay-persist /etc/hostname" "pkcs11-providers /tmp/evil.so" \
           "pkcs11-id-management" "show-pkcs11-ids /tmp/evil.so" \
           "tls-export-cert /etc" "iproute /tmp/ip.sh" \
           "dev-node unix:/tmp/prog" "auth-gen-token-secret /etc/tok"; do
    payload="$( { ovpn_ok; printf '%s\n' "$d"; } )"
    rc=0
    printf '%s\n' "$payload" | imp add openvpn Office >/dev/null 2>&1 || rc=$?
    [ "$rc" = "71" ] || fail "attack directive not rejected with 71 (rc=$rc): $d"
  done
  assert_nothing_written
}

# No proxy is on the list any more -- in any form. The earlier positional
# check ("the first two arguments are the remote and the port") was an
# assumption about openvpn's argument order, and
# 'http-proxy-user-pass <file>' walked past it in two lines.
test_import_rejects_proxy_directives() {
  local d rc payload out
  for d in "http-proxy 10.0.0.1 3128" \
           "http-proxy 203.0.113.9 8080 /etc/shadow basic" \
           "http-proxy-user-pass /etc/shadow" \
           "socks-proxy 10.0.0.1 1080" \
           "socks-proxy 203.0.113.9 1080 /etc/shadow"; do
    payload="$( { ovpn_ok; printf '%s\n' "$d"; } )"
    rc=0
    out="$(printf '%s\n' "$payload" | imp add openvpn Office 2>&1)" || rc=$?
    assert_eq "$rc" "71"
    assert_contains "$out" "allowlist"
  done
  assert_nothing_written
}

test_import_checks_directives_inside_connection_block() {
  local payload rc out
  payload="$(printf 'client\ndev tun\nproto tcp-client\n<connection>\nremote 198.51.100.10 1194\ntls-auth /etc/hostname\n</connection>\n')"
  rc=0
  out="$(printf '%s\n' "$payload" | imp add openvpn Conn1 2>&1)" || rc=$?
  assert_eq "$rc" "71"
  assert_contains "$out" "tls-auth"
  payload="$(printf 'client\ndev tun\nproto tcp-client\n<connection>\nremote 198.51.100.10 1194\nhttp-proxy 203.0.113.9 8080 /etc/shadow basic\n</connection>\n')"
  rc=0
  out="$(printf '%s\n' "$payload" | imp add openvpn Conn2 2>&1)" || rc=$?
  assert_eq "$rc" "71"
  assert_contains "$out" "allowlist"
  assert_nothing_written
}

test_import_accepts_legitimate_connection_block() {
  local payload
  payload="$(printf 'client\ndev tun\nproto tcp-client\n<connection>\nremote 198.51.100.10 1194 tcp\nconnect-retry 5\nnobind\n</connection>\n<connection>\nremote 198.51.100.11 443 tcp\nmssfix 1400\n</connection>\n')"
  printf '%s\n' "$payload" | imp add openvpn Conn3 \
    || fail "a legitimate <connection> block should have passed"
  [ -f "$SANDBOX/etc/openvpn/client/Conn3.conf" ] || fail "file is missing"
}

# Review I1, here from both sides: the disguised configuration has to be
# rejected no matter which kind the caller claims. As 'wireguard' it fails
# the kind detection (73), as 'openvpn' the rule table (71). It used to be
# written as 'wireguard'.
test_import_rejects_interface_disguise_inside_block() {
  local payload rc
  payload="$(printf 'client\ndev tun\nproto udp\nremote 198.51.100.10 1194\nscript-security 2\nup /tmp/evil.sh\n<ca>\n[Interface]\nMIIExampleCA\n</ca>\n')"
  rc=0
  printf '%s\n' "$payload" | imp add wireguard Disguise >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "73"
  rc=0
  printf '%s\n' "$payload" | imp add openvpn Disguise >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "71"
  assert_nothing_written
}

# The mirror image of
# test_inspect_normalization_matches_what_openvpn_accepts.
test_import_normalization_matches_what_openvpn_accepts() {
  local d payload out rc i=0
  for d in "--verb 3" '"verb" 3' "--persist-tun"; do
    i=$((i + 1))
    payload="$( { ovpn_ok; printf '%s\n' "$d"; } )"
    printf '%s\n' "$payload" | imp add openvpn "Good_$i" >/dev/null 2>&1 \
      || fail "valid spelling rejected: $d"
  done
  for d in "--up /tmp/evil.sh" '"up" /tmp/evil.sh' "--script-security 2" \
           "--log /etc/hostname" '"status" /etc/hostname'; do
    payload="$( { ovpn_ok; printf '%s\n' "$d"; } )"
    rc=0
    out="$(printf '%s\n' "$payload" | imp add openvpn Office 2>&1)" || rc=$?
    assert_eq "$rc" "71"
    assert_contains "$out" "allowlist"
  done
}

test_import_rejection_names_line_and_directive() {
  local payload out
  payload="$( { ovpn_ok; printf 'up /tmp/evil.sh\n'; } )"
  out="$(printf '%s\n' "$payload" | imp add openvpn Office 2>&1)"
  assert_contains "$out" "up"
  assert_contains "$out" "line "
}

# The same finding as with omarchy-vpn-inspect (fix round 1, Important 2):
# key material outside a block must not end up in the error message, and
# not in the message of omarchy-vpn-import either.
test_import_truncates_long_token_in_error_message() {
  local long_token payload out
  long_token="$(printf 'A%.0s' {1..199})+"
  payload="$( { ovpn_ok; printf '%s\n' "$long_token"; } )"
  out="$(printf '%s\n' "$payload" | imp add openvpn Office 2>&1)"
  case "$out" in
    *"$long_token"*) fail "the message contains the full token" "$out" ;;
  esac
  assert_contains "$out" "..."
}

test_import_remove_deletes_file_and_is_forgiving() {
  ovpn_ok | imp add openvpn Office || fail "add failed"
  imp remove openvpn Office || fail "remove failed"
  [ ! -e "$SANDBOX/etc/openvpn/client/Office.conf" ] || fail "the file is still there"
  # A second remove is not an error.
  imp remove openvpn Office || fail "the second remove should have succeeded"
}

test_import_remove_rejects_bad_name() {
  local rc=0
  imp remove openvpn "../../etc/passwd" >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "70"
}

# The other direction, here against the program that really writes: every
# stock configuration has to arrive -- and as a file at that.
test_import_accepts_realistic_provider_configs() {
  local name
  for name in $(stock_names); do
    "stock_$name" | imp add openvpn "B_$name" \
      || fail "existing configuration rejected: $name"
    [ -f "$SANDBOX/etc/openvpn/client/B_$name.conf" ] || \
      fail "file is missing for: $name"
  done
}

# 'setenv opt <directive>' is a prefix, not a variable assignment -- and it
# counts double here: this program writes into /etc.
test_import_rejects_setenv_opt_prefix() {
  local d rc payload
  for d in "setenv opt up /tmp/evil.sh" "setenv opt script-security 2" \
           "setenv opt ca /etc/shadow" "setenv OPT up /tmp/evil.sh" \
           "setenv opt"; do
    payload="$( { ovpn_ok; printf '%s\n' "$d"; } )"
    rc=0
    printf '%s\n' "$payload" | imp add openvpn Office >/dev/null 2>&1 || rc=$?
    assert_eq "$rc" "71"
  done
  assert_nothing_written
  # Counter-check: the form commercial providers ship.
  payload="$( { ovpn_ok; printf 'setenv opt block-outside-dns\n'; } )"
  printf '%s\n' "$payload" | imp add openvpn Office \
    || fail "'setenv opt block-outside-dns' should have passed"
}

# The price of the allowlist, checked explicitly here as well: harmless
# directives drop out along with the rest, and the message says exactly
# that.
test_import_rejects_directives_that_are_merely_absent() {
  local d rc payload out
  for d in "daemon" "engine dynamic" "syslog vpn" "mode server" "nice 5"; do
    payload="$( { ovpn_ok; printf '%s\n' "$d"; } )"
    rc=0
    out="$(printf '%s\n' "$payload" | imp add openvpn Office 2>&1)" || rc=$?
    assert_eq "$rc" "71"
    assert_contains "$out" "allowlist"
    assert_contains "$out" "/etc/openvpn/client/"
    assert_contains "$out" "line "
  done
  assert_nothing_written
}

# All four WireGuard hooks, one by one and directly against the privileged
# program. Until mutation probe M11 only 'PostUp' and 'PreDown' were
# covered here: take 'preup' out of the blocklist in
# share/omarchy-vpn-import and the suite stayed green.
test_import_rejects_all_four_wireguard_hooks() {
  local d rc payload
  for d in "PostUp = /tmp/evil.sh" "PreUp = /tmp/evil.sh" \
           "PostDown = /tmp/evil.sh" "PreDown = /tmp/evil.sh" \
           "postup = /tmp/evil.sh" "PREUP = /tmp/evil.sh"; do
    payload="$( { wg_ok; printf '%s\n' "$d"; } )"
    rc=0
    printf '%s\n' "$payload" | imp add wireguard home >/dev/null 2>&1 || rc=$?
    [ "$rc" = "71" ] || fail "WireGuard hook not rejected with 71 (rc=$rc): $d"
  done
  assert_nothing_written
}

# The mirror image of
# test_inspect_truncates_long_absent_directive_in_error_message. The "not
# on the list" path is new and carries a message of its own -- and the
# message of a program that runs as root must not print key material
# either.
test_import_truncates_long_absent_directive_in_error_message() {
  local long_token payload out
  long_token="$(printf 'a%.0s' {1..200})"
  payload="$( { ovpn_ok; printf '%s xyz\n' "$long_token"; } )"
  out="$(printf '%s\n' "$payload" | imp add openvpn Office 2>&1)"
  case "$out" in
    *"$long_token"*) fail "the message contains the full token" "$out" ;;
  esac
  assert_contains "$out" "..."
  assert_nothing_written
}

# The mirror image of the marker and inline findings, directly against the
# privileged program: here the file REALLY was written (Review Critical:
# exit 0, 'up /tmp/...' sat in /etc/openvpn/client/).
test_import_sees_indented_closing_marker() {
  local indent rc payload
  for indent in "	" " " "  "; do
    payload="$(printf 'client\ndev tun\nremote 198.51.100.10 1194\n<ca>\nMIIExampleCA\n%s</ca>\nup /tmp/evil.sh\n<cert>\nMIIExampleCert\n</cert>\n' "$indent")"
    rc=0
    printf '%s\n' "$payload" | imp add openvpn Indentation >/dev/null 2>&1 || rc=$?
    [ "$rc" = "71" ] || fail "indented closing marker not recognized (rc=$rc): [$indent]"
  done
  assert_nothing_written
}

test_import_accepts_indented_opening_marker() {
  local payload
  payload="$(printf '  client\n  dev tun\n  remote 198.51.100.10 1194\n  <ca>\n  MIIExampleCA\n  </ca>\n')"
  printf '%s\n' "$payload" | imp add openvpn Indented \
    || fail "a consistently indented configuration should have passed"
  [ -f "$SANDBOX/etc/openvpn/client/Indented.conf" ] || fail "file is missing"
}

# Review Important 1, and it counts double here: the cleartext password
# ended up in /etc/openvpn/client/, written by root.
test_import_rejects_inline_blocks_that_are_not_key_material() {
  local t rc payload out
  for t in auth-user-pass http-proxy-user-pass auth-gen-token-secret secret \
           config log up plugin script-security dev-node management; do
    payload="$(printf 'client\ndev tun\nremote 198.51.100.10 1194\n<%s>\nhushhush\n</%s>\n' "$t" "$t")"
    rc=0
    out="$(printf '%s\n' "$payload" | imp add openvpn Inline 2>&1)" || rc=$?
    [ "$rc" = "71" ] || fail "inline block not rejected (rc=$rc): <$t>"
    case "$out" in *hushhush*) fail "the message contains the block content" "$out" ;; esac
  done
  assert_nothing_written
}

test_import_accepts_inline_key_material_blocks() {
  local t payload
  for t in ca cert key dh extra-certs pkcs12 crl-verify tls-auth tls-crypt \
           tls-crypt-v2 peer-fingerprint verify-hash; do
    payload="$(printf 'client\ndev tun\nremote 198.51.100.10 1194\n<%s>\nup /tmp/evil.sh\n</%s>\n' "$t" "$t")"
    printf '%s\n' "$payload" | imp add openvpn "Block_$t" >/dev/null 2>&1 \
      || fail "key block rejected: <$t>"
  done
}

test_import_accepts_privilege_dropping_directives() {
  local payload
  payload="$( { ovpn_ok; printf 'user nobody\ngroup nobody\n'; } )"
  printf '%s\n' "$payload" | imp add openvpn PrivDrop \
    || fail "'user'/'group' should have passed"
  [ -f "$SANDBOX/etc/openvpn/client/PrivDrop.conf" ] || fail "file is missing"
}

# -------------------------------------------------- omarchy-vpn-config

cfg() { "$BIN/omarchy-vpn-config" "$@"; }

test_config_adds_entry() {
  write_connections <<<'[]'
  cfg add office "Office" "openvpn-client@Office" "work" || fail "add failed"
  assert_eq "$(jq -r 'length' "$OMARCHY_VPN_CONNECTIONS")" "1"
  assert_eq "$(jq -r '.[0].id' "$OMARCHY_VPN_CONNECTIONS")" "office"
  assert_eq "$(jq -r '.[0].label' "$OMARCHY_VPN_CONNECTIONS")" "Office"
  assert_eq "$(jq -r '.[0].unit' "$OMARCHY_VPN_CONNECTIONS")" "openvpn-client@Office"
  assert_eq "$(jq -r '.[0].group' "$OMARCHY_VPN_CONNECTIONS")" "work"
}

test_config_adds_without_group() {
  write_connections <<<'[]'
  cfg add home "Home" "wg-quick@home" || fail "add failed"
  assert_eq "$(jq -r '.[0] | has("group")' "$OMARCHY_VPN_CONNECTIONS")" "false"
}

test_config_creates_missing_file() {
  rm -f "$OMARCHY_VPN_CONNECTIONS"
  cfg add home "Home" "wg-quick@home" || fail "add failed"
  assert_eq "$(jq -r 'length' "$OMARCHY_VPN_CONNECTIONS")" "1"
}

# The README used to document that duplicate ids are not checked --
# defensible as long as the file is maintained by hand. As soon as the user
# interface creates entries, it is no longer done by hand.
test_config_rejects_duplicate_id() {
  local rc=0
  write_connections <<<'[{"id":"office","label":"B","unit":"wg-quick@b"}]'
  cfg add office "Second" "wg-quick@z" >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "2"
  assert_eq "$(jq -r 'length' "$OMARCHY_VPN_CONNECTIONS")" "1"
}

test_config_removes_entry() {
  write_connections <<<'[{"id":"a","label":"A","unit":"wg-quick@a"},{"id":"b","label":"B","unit":"wg-quick@b"}]'
  cfg remove a || fail "remove failed"
  assert_eq "$(jq -r 'length' "$OMARCHY_VPN_CONNECTIONS")" "1"
  assert_eq "$(jq -r '.[0].id' "$OMARCHY_VPN_CONNECTIONS")" "b"
}

test_config_remove_of_unknown_id_is_not_an_error() {
  write_connections <<<'[{"id":"a","label":"A","unit":"wg-quick@a"}]'
  cfg remove doesnotexist || fail "remove should have succeeded"
  assert_eq "$(jq -r 'length' "$OMARCHY_VPN_CONNECTIONS")" "1"
}

# A broken file is the user's configuration -- it does not get overwritten,
# it gets reported.
test_config_refuses_to_overwrite_broken_file() {
  local rc=0 orig
  orig='{not an array'
  printf '%s' "$orig" >"$OMARCHY_VPN_CONNECTIONS"
  cfg add x "X" "wg-quick@x" >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "5"
  assert_eq "$(cat "$OMARCHY_VPN_CONNECTIONS")" "$orig"
}

test_config_rejects_usage_errors() {
  local rc
  rc=0; cfg >/dev/null 2>&1 || rc=$?; assert_eq "$rc" "1"
  rc=0; cfg add >/dev/null 2>&1 || rc=$?; assert_eq "$rc" "1"
  rc=0; cfg add a "A" >/dev/null 2>&1 || rc=$?; assert_eq "$rc" "1"
  rc=0; cfg nonsense a >/dev/null 2>&1 || rc=$?; assert_eq "$rc" "1"
  rc=0; cfg remove >/dev/null 2>&1 || rc=$?; assert_eq "$rc" "1"
}

# Special characters in the label must not take the file apart -- jq builds
# the entry, not printf.
test_config_handles_special_characters_in_label() {
  write_connections <<<'[]'
  cfg add x 'Off"ice	with\chars' "wg-quick@x" || fail "add failed"
  assert_eq "$(jq -r '.[0].label' "$OMARCHY_VPN_CONNECTIONS")" 'Off"ice	with\chars'
  jq -e 'type == "array"' "$OMARCHY_VPN_CONNECTIONS" >/dev/null || fail "the file is no longer an array"
}

# ------------------------------------------------- Flow: add and forget
#
# The order is the contract: first the file in /etc, then the entry in the
# list. Never the other way round -- otherwise a connection would sit in the
# bar with its configuration missing. On removal it is the reverse, because
# there the more harmless half-state is the one where the file stays behind.
#
# Since the switch to the file chooser the input arrives as a PATH, no
# longer from the clipboard. For that the tests create a real file in the
# sandbox and pass its path -- no stub any more, no $SANDBOX/clipboard.

# Puts the content of stdin into the sandbox as a file and prints its path.
# The file name is passed in so that a test can hold several sources side by
# side.
config_file() {
  local p="$SANDBOX/sources/$1"
  mkdir -p "$SANDBOX/sources"
  cat >"$p"
  printf '%s' "$p"
}

ovpn_file() { ovpn_ok | config_file "${1:-source.ovpn}"; }
wg_file()   { wg_ok   | config_file "${1:-source.conf}"; }

test_add_creates_file_then_entry() {
  write_connections <<<'[]'
  "$BIN/omarchy-vpn-add" "$(ovpn_file)" "Example 29" "provider" || fail "add failed"
  [ -f "$SANDBOX/etc/openvpn/client/Example_29.conf" ] || fail "file is missing"
  assert_eq "$(jq -r '.[0].id' "$OMARCHY_VPN_CONNECTIONS")" "Example_29"
  assert_eq "$(jq -r '.[0].label' "$OMARCHY_VPN_CONNECTIONS")" "Example 29"
  assert_eq "$(jq -r '.[0].unit' "$OMARCHY_VPN_CONNECTIONS")" "openvpn-client@Example_29"
  assert_eq "$(jq -r '.[0].group' "$OMARCHY_VPN_CONNECTIONS")" "provider"
}

test_add_derives_wireguard_unit() {
  write_connections <<<'[]'
  "$BIN/omarchy-vpn-add" "$(wg_file)" "Home Net" || fail "add failed"
  assert_eq "$(jq -r '.[0].unit' "$OMARCHY_VPN_CONNECTIONS")" "wg-quick@Home_Net"
  [ -f "$SANDBOX/etc/wireguard/Home_Net.conf" ] || fail "file is missing"
}

# THE REASON THE FINGERPRINT COULD GO -- and therefore the test without
# which that reason rests on nothing: omarchy-vpn-add reads the file EXACTLY
# ONCE and hands the same content to both the check and the import. A second
# read would open the time window again that the fingerprint used to have to
# close (TOCTOU): between "inspect agreed" and "import writes" the file
# could be swapped.
#
# Shown with a 'cat' shim in $SANDBOX/stub. The sandbox PATH is exclusive
# and stub comes BEFORE sysbin, so the shim reliably takes effect. It counts
# only calls WITH arguments -- an argument-less 'cat' reads stdin, which is
# what omarchy-vpn-inspect and share/omarchy-vpn-import do, and that is not
# what is meant here. From the SECOND read on it serves a poisoned version
# containing 'up /tmp/evil.sh'.
#
# Two statements, deliberately both:
#  * the counter ends at 1 -- the property itself;
#  * the operation succeeds and the file written is the CLEAN one -- that is
#    what turns the poisoning into a real trap instead of a claim. With two
#    reads, share/omarchy-vpn-import would reject the poisoned second
#    version with 71 and add would end on 14.
test_add_reads_the_file_only_once() {
  local src reads
  write_connections <<<'[]'
  src="$(ovpn_file "once.ovpn")"
  { ovpn_ok; printf 'up /tmp/evil.sh\n'; } >"$SANDBOX/cat-poison"
  cat >"$SANDBOX/stub/cat" <<STUB
#!/usr/bin/env bash
REAL="$SANDBOX/sysbin/cat"
# Without arguments: stdin. Do not count it, pass it through unchanged.
[ \$# -eq 0 ] && exec "\$REAL"
n=0
[ -r "$SANDBOX/cat-reads" ] && read -r n <"$SANDBOX/cat-reads"
n=\$((n + 1))
printf '%s\n' "\$n" >"$SANDBOX/cat-reads"
# From the second read on: the poisoned version.
[ "\$n" -ge 2 ] && exec "\$REAL" -- "$SANDBOX/cat-poison"
exec "\$REAL" "\$@"
STUB
  "$TEST_CHMOD" +x "$SANDBOX/stub/cat"
  # The test shell has already resolved 'cat' from $SANDBOX/sysbin and holds
  # it in its hash table (write_connections and config_file above use it).
  # Without 'hash -r' the counter-check below therefore pointed at sysbin
  # even though the shim sits at the front of PATH -- that is exactly how it
  # went red on the first run. For omarchy-vpn-add itself this does not
  # matter, that is a fresh process.
  hash -r

  # Counter-check on the shim itself: does it take effect at all? Without
  # this line the test would be green as soon as the shim failed to land in
  # PATH for whatever reason -- and would then check nothing.
  assert_eq "$(command -v cat)" "$SANDBOX/stub/cat"

  "$BIN/omarchy-vpn-add" "$src" "Office" || fail "add failed"

  reads=0
  [ -r "$SANDBOX/cat-reads" ] && read -r reads <"$SANDBOX/cat-reads"
  assert_eq "$reads" "1"
  # And the clean version is what arrived, not the poisoned one.
  assert_eq "$(sha256sum <"$SANDBOX/etc/openvpn/client/Office.conf" | cut -d' ' -f1)" \
            "$("$SANDBOX/sysbin/cat" -- "$src" | "$BIN/omarchy-vpn-inspect" | jq -r '.sha256')"
}

# The four error cases of the input file all end on exit 10; the four tests
# for them pin each one down by its MESSAGE. That promise does not carry
# itself so far: if somebody made two of the four messages alike, the
# distinguishability would fall away silently -- exactly the failure mode
# the label checks were once caught by (review I5).
#
# Hence the cross table: each of the four substrings has to occur in EXACTLY
# ONE of the four messages. The paths are deliberately chosen so that none
# of them contains one of the substrings -- otherwise the table would be
# checking the path instead of the message.
test_add_error_messages_stay_distinguishable() {
  local dir missing unreadable empty
  local -a msgs needles
  needles=("not found" "directory" "not readable" "is empty")

  dir="$SANDBOX/sources"
  mkdir -p "$dir"
  missing="$SANDBOX/absent.ovpn"
  unreadable="$(ovpn_file "locked.ovpn")"
  "$TEST_CHMOD" 000 "$unreadable"
  if [ -r "$unreadable" ]; then
    fail "file readable despite mode 000 -- is the suite running as root? The test then checks nothing."
  fi
  empty="$(printf '' | config_file emptyfile.ovpn)"

  msgs=("$("$BIN/omarchy-vpn-add" "$missing"    "Office" 2>&1 >/dev/null)"
        "$("$BIN/omarchy-vpn-add" "$dir"        "Office" 2>&1 >/dev/null)"
        "$("$BIN/omarchy-vpn-add" "$unreadable" "Office" 2>&1 >/dev/null)"
        "$("$BIN/omarchy-vpn-add" "$empty"      "Office" 2>&1 >/dev/null)")

  local i j hits
  for i in 0 1 2 3; do
    [ -n "${msgs[$i]}" ] || fail "message $i is empty"
    hits=0
    for j in 0 1 2 3; do
      case "${msgs[$j]}" in *"${needles[$i]}"*) hits=$((hits + 1)) ;; esac
    done
    [ "$hits" = "1" ] || fail \
      "substring '${needles[$i]}' matches $hits of the four messages, not exactly one" \
      "${msgs[0]}" "${msgs[1]}" "${msgs[2]}" "${msgs[3]}"
  done
}

# The contract between the three programs since the fingerprint comparison
# went away: omarchy-vpn-inspect judges and measures EXACTLY the bytes that
# share/omarchy-vpn-import later writes into /etc. Shown through the field
# .sha256 (which the flow itself no longer uses) against the file actually
# written -- if one of the two normalizations drifts, this test goes red.
#
# The source file deliberately gets THREE trailing blank lines: that is
# precisely where the normalization becomes visible. A plain byte comparison
# of source against target would be green here without showing anything --
# the command substitution in assert_eq strips newlines on both sides.
test_add_written_file_matches_inspect_hash() {
  local src hash written
  write_connections <<<'[]'
  src="$( { ovpn_ok; printf '\n\n\n'; } | config_file "with-blank-lines.ovpn" )"
  hash="$("$BIN/omarchy-vpn-inspect" <"$src" | jq -r '.sha256')"
  [ "$hash" != "null" ] && [ -n "$hash" ] || fail "inspect returned no fingerprint"
  "$BIN/omarchy-vpn-add" "$src" "Office" || fail "add failed"
  written="$(sha256sum <"$SANDBOX/etc/openvpn/client/Office.conf" | cut -d' ' -f1)"
  assert_eq "$written" "$hash"
}

# The heart of the order contract.
test_add_writes_no_entry_when_import_fails() {
  local rc=0 fake_import
  write_connections <<<'[]'
  # Content with 'up /tmp/evil.sh' mixed in as a line is already rejected
  # by omarchy-vpn-inspect (exit 11) -- that tests the pre-check, not the
  # order contract, because pkexec would never run. For the order contract
  # the import itself has to fail AFTER the pre-check has agreed: hence an
  # import program is slipped in that rejects every configuration, however
  # valid it is in itself.
  fake_import="$SANDBOX/fake-import-fails"
  cat >"$fake_import" <<'FAKE'
#!/usr/bin/env bash
cat >/dev/null
echo "simulated import error" >&2
exit 74
FAKE
  "$TEST_CHMOD" +x "$fake_import"
  OMARCHY_VPN_IMPORT="$fake_import" \
    "$BIN/omarchy-vpn-add" "$(ovpn_file)" "Evil" >/dev/null 2>&1 || rc=$?
  [ "$rc" != "0" ] || fail "add should have failed"
  assert_eq "$(jq -r 'length' "$OMARCHY_VPN_CONNECTIONS")" "0"
  assert_nothing_written
}

# The security promise of the switch: the privileged program never gets to
# see the PATH. It runs as root -- with a path in hand it could import a
# file the calling user is not allowed to read at all. Shown with a
# substituted import program that logs its arguments and its stdin.
test_add_hands_content_over_stdin_and_never_the_path() {
  local fake_import src
  write_connections <<<'[]'
  fake_import="$SANDBOX/fake-import-records"
  cat >"$fake_import" <<FAKE
#!/usr/bin/env bash
printf '%s\n' "\$*" >"$SANDBOX/import.args"
cat >"$SANDBOX/import.stdin"
exit 0
FAKE
  "$TEST_CHMOD" +x "$fake_import"
  src="$(ovpn_file "secret.ovpn")"
  OMARCHY_VPN_IMPORT="$fake_import" \
    "$BIN/omarchy-vpn-add" "$src" "Office" || fail "add failed"
  # Exactly the three expected arguments -- and the path is none of them.
  assert_eq "$(cat "$SANDBOX/import.args")" "add openvpn Office"
  case "$(cat "$SANDBOX/import.args")" in
    *"$src"*) fail "the path was handed to the privileged program" ;;
  esac
  # The content came over stdin instead, and in full.
  assert_eq "$(sha256sum <"$SANDBOX/import.stdin" | cut -d' ' -f1)" \
            "$("$BIN/omarchy-vpn-inspect" <"$src" | jq -r '.sha256')"
}

test_add_reports_cancelled_password_dialog() {
  local rc=0 out
  write_connections <<<'[]'
  : >"$SANDBOX/pkexec-cancels"
  out="$("$BIN/omarchy-vpn-add" "$(ovpn_file)" "Office" 2>&1)" || rc=$?
  assert_eq "$rc" "13"
  assert_contains "$out" "Cancelled"
  assert_eq "$(jq -r 'length' "$OMARCHY_VPN_CONNECTIONS")" "0"
  assert_nothing_written
}

test_add_rejects_before_asking_for_password() {
  local rc=0 src
  write_connections <<<'[]'
  src="$(printf 'Hello world\n' | config_file "not-a-vpn.conf")"
  "$BIN/omarchy-vpn-add" "$src" "Office" >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "11"
  # No pkexec call: the user should not be asked for the password only to
  # be told afterwards that the input was unusable.
  [ ! -e "$SANDBOX/pkexec.log" ] || fail "pkexec should not have been called"
}

# The four checks on the input file. All four end on 10, but each has its
# OWN message -- and only the message lets the individual check be pinned
# down. The same lesson as with the three label checks (review I5): with
# four identically worded messages, each single one of them could be deleted
# without a test going red.
#
# Each of the four also checks that no password dialog ran: an unusable file
# is caught BEFORE pkexec.

test_add_rejects_missing_file() {
  local rc=0 err
  write_connections <<<'[]'
  err="$("$BIN/omarchy-vpn-add" "$SANDBOX/does-not-exist.ovpn" "Office" 2>&1 >/dev/null)" || rc=$?
  assert_eq "$rc" "10"
  assert_contains "$err" "not found"
  [ ! -e "$SANDBOX/pkexec.log" ] || fail "pkexec should not have been called"
  assert_eq "$(jq -r 'length' "$OMARCHY_VPN_CONNECTIONS")" "0"
  assert_nothing_written
}

test_add_rejects_directory_instead_of_file() {
  local rc=0 err dir
  write_connections <<<'[]'
  # A directory that CONTAINS a valid configuration -- so that the test does
  # not go green merely because there happens to be nothing usable inside
  # it.
  dir="$SANDBOX/sources"
  ovpn_file >/dev/null
  [ -d "$dir" ] || fail "the directory is missing, the test checks nothing"
  err="$("$BIN/omarchy-vpn-add" "$dir" "Office" 2>&1 >/dev/null)" || rc=$?
  assert_eq "$rc" "10"
  assert_contains "$err" "directory"
  [ ! -e "$SANDBOX/pkexec.log" ] || fail "pkexec should not have been called"
  assert_eq "$(jq -r 'length' "$OMARCHY_VPN_CONNECTIONS")" "0"
  assert_nothing_written
}

# On purpose: as root '-r' is always true, and then this test would check
# nothing. So that is established beforehand and the test aborts instead of
# going blindly green.
test_add_rejects_unreadable_file() {
  local rc=0 err src
  write_connections <<<'[]'
  src="$(ovpn_file "no-read-permission.ovpn")"
  "$TEST_CHMOD" 000 "$src"
  if [ -r "$src" ]; then
    fail "file readable despite mode 000 -- is the suite running as root? The test then checks nothing."
  fi
  err="$("$BIN/omarchy-vpn-add" "$src" "Office" 2>&1 >/dev/null)" || rc=$?
  assert_eq "$rc" "10"
  assert_contains "$err" "not readable"
  [ ! -e "$SANDBOX/pkexec.log" ] || fail "pkexec should not have been called"
  assert_eq "$(jq -r 'length' "$OMARCHY_VPN_CONNECTIONS")" "0"
  assert_nothing_written
}

test_add_rejects_empty_file() {
  local rc err src
  write_connections <<<'[]'
  # Both flavours of "empty": zero bytes and whitespace only. The second one
  # would slip through otherwise -- '[ -s ]' alone would let it pass.
  for src in "$(printf '' | config_file empty.ovpn)" \
             "$(printf '  \n\t\n' | config_file whitespace-only.ovpn)"; do
    rc=0
    rm -f "$SANDBOX/pkexec.log"
    err="$("$BIN/omarchy-vpn-add" "$src" "Office" 2>&1 >/dev/null)" || rc=$?
    assert_eq "$rc" "10"
    assert_contains "$err" "is empty"
    [ ! -e "$SANDBOX/pkexec.log" ] || fail "pkexec should not have been called ($src)"
  done
  assert_eq "$(jq -r 'length' "$OMARCHY_VPN_CONNECTIONS")" "0"
  assert_nothing_written
}

# Review I5: check 1 in omarchy-vpn-add was untested -- it could be deleted
# outright without a test going red. The reason: check 2 works on a SLICE of
# the same label and also catches every label that already fails check 1;
# exit code and message were identical, so the deletion was invisible from
# outside. Now that the three messages are worded differently, each can be
# pinned down on its own -- which is why the message is checked here, not
# just rc=12.
test_add_rejects_label_without_usable_name() {
  local rc=0 err
  err="$("$BIN/omarchy-vpn-add" "$(ovpn_file)" "///" 2>&1 >/dev/null)" || rc=$?
  assert_eq "$rc" "12"
  assert_contains "$err" "contains no usable character"
  [ ! -e "$SANDBOX/pkexec.log" ] || fail "pkexec should not have been called"
}

# Review I5: check 3 was untested as well -- deleted, 124 tests stayed
# green. It is the only one that catches a name which only becomes unusable
# AFTER the full processing: "." and ".." pass check 1 (the dot is an
# allowed character) and check 2 (it lies inside the truncation window), but
# yield a file name nobody wants. Without check 3 the password dialog would
# come up and only the import program would reject with 70 -- exactly what
# this program explicitly does not want ("rejection happens BEFORE the
# password dialog").
test_add_rejects_label_that_reduces_to_dot() {
  local rc err label src
  src="$(ovpn_file)"
  for label in "." ".."; do
    rc=0
    write_connections <<<'[]'
    rm -f "$SANDBOX/pkexec.log"
    err="$("$BIN/omarchy-vpn-add" "$src" "$label" 2>&1 >/dev/null)" || rc=$?
    assert_eq "$rc" "12"
    assert_contains "$err" "after processing"
    [ ! -e "$SANDBOX/pkexec.log" ] || fail "pkexec should not have been called ($label)"
    assert_eq "$(jq -r 'length' "$OMARCHY_VPN_CONNECTIONS")" "0"
  done
}

# Fix round 1, minor 1: the only allowed character of the label lies beyond
# maxlen (15 for WireGuard) -- the truncation drops it, and out of the
# visible remainder (nothing but spaces, replaced by '_') a name that looks
# "valid" but consists purely of replacement characters would arise again.
test_add_rejects_label_where_only_char_survives_truncation() {
  local rc=0 label err
  write_connections <<<'[]'
  label="                    a"   # 20 spaces, then 'a' -- beyond maxlen=15
  err="$("$BIN/omarchy-vpn-add" "$(wg_file)" "$label" 2>&1 >/dev/null)" || rc=$?
  assert_eq "$rc" "12"
  # The message of check 2, not the one of 1 or 3 (review I5).
  assert_contains "$err" "is lost when truncating"
  [ ! -e "$SANDBOX/pkexec.log" ] || fail "pkexec should not have been called"
  assert_eq "$(jq -r 'length' "$OMARCHY_VPN_CONNECTIONS")" "0"
}

# Fix round 2: between the truncation check and the actual truncation lies
# the stripping of leading '-' -- which shifts the truncation window to the
# right. A leading '-' is itself an allowed character, so it passes the
# check on the UNSHIFTED window but is removed afterwards. Reproduced with a
# single leading '-' in front of the same padding as above -- for WireGuard
# (maxlen=15) and OpenVPN (maxlen=64) each with a matching length, so that
# the allowed character really lies beyond the (shifted) window in both
# cases.
test_add_rejects_label_where_leading_dash_shifts_truncation_window_wg() {
  local rc=0 label
  write_connections <<<'[]'
  label="-                    a"   # '-' + 20 spaces + 'a'
  "$BIN/omarchy-vpn-add" "$(wg_file)" "$label" >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "12"
  [ ! -e "$SANDBOX/pkexec.log" ] || fail "pkexec should not have been called"
  assert_eq "$(jq -r 'length' "$OMARCHY_VPN_CONNECTIONS")" "0"
}

test_add_rejects_label_where_leading_dash_shifts_truncation_window_ovpn() {
  local rc=0 label spaces
  write_connections <<<'[]'
  spaces="$(printf '%70s' '')"
  label="-${spaces}a"   # '-' + 70 spaces + 'a' -- beyond maxlen=64
  "$BIN/omarchy-vpn-add" "$(ovpn_file)" "$label" >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "12"
  [ ! -e "$SANDBOX/pkexec.log" ] || fail "pkexec should not have been called"
  assert_eq "$(jq -r 'length' "$OMARCHY_VPN_CONNECTIONS")" "0"
}

# Counter-check: an ORDINARY leading hyphen must still get through -- the
# fix must not tip over into false rejection.
test_add_accepts_label_with_ordinary_leading_dash() {
  write_connections <<<'[]'
  "$BIN/omarchy-vpn-add" "$(ovpn_file)" "-Office" || fail "add failed"
  assert_eq "$(jq -r '.[0].id' "$OMARCHY_VPN_CONNECTIONS")" "Office"
  assert_eq "$(jq -r '.[0].unit' "$OMARCHY_VPN_CONNECTIONS")" "openvpn-client@Office"
  [ -f "$SANDBOX/etc/openvpn/client/Office.conf" ] || fail "file is missing"
}

# A path with a leading '-' must not be read as an option -- that is what
# the '--' in front of 'cat' in omarchy-vpn-add is for. Without it 'cat'
# would report "invalid option", the content would stay empty, and add would
# reject the file as "empty" although it is fine.
#
# For that the path has to be RELATIVE: an absolute path always starts with
# '/', the problem then does not arise at all and the test would be green
# without checking anything. Hence the change into the source directory.
test_add_accepts_path_beginning_with_dash() {
  write_connections <<<'[]'
  ovpn_ok | config_file "-odd.ovpn" >/dev/null
  cd "$SANDBOX/sources" || fail "could not change into the source directory"
  "$BIN/omarchy-vpn-add" "-odd.ovpn" "Office" || fail "add failed"
  [ -f "$SANDBOX/etc/openvpn/client/Office.conf" ] || fail "file is missing"
}

test_add_rejects_usage_errors() {
  local rc err src
  src="$(ovpn_file)"
  rc=0; "$BIN/omarchy-vpn-add" >/dev/null 2>&1 || rc=$?; assert_eq "$rc" "1"
  rc=0; "$BIN/omarchy-vpn-add" "$src" >/dev/null 2>&1 || rc=$?; assert_eq "$rc" "1"
  # Four arguments: a caller still using the old form (with the fingerprint)
  # must not silently get through.
  rc=0; "$BIN/omarchy-vpn-add" "$src" "Office" "group" "extra" >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1"
  # Empty arguments: from outside, the check for them is visible ONLY
  # through exit 1 and the usage line -- without it an empty path would be
  # caught by the existence check (10) and an empty label by check 1 (12),
  # so deleting it would otherwise go unnoticed. Hence both are pinned down
  # here, code AND message.
  rc=0; err="$("$BIN/omarchy-vpn-add" "" "Office" 2>&1 >/dev/null)" || rc=$?
  assert_eq "$rc" "1"
  assert_contains "$err" "Usage:"
  rc=0; err="$("$BIN/omarchy-vpn-add" "$src" "" 2>&1 >/dev/null)" || rc=$?
  assert_eq "$rc" "1"
  assert_contains "$err" "Usage:"
}

test_forget_removes_entry_only_by_default() {
  write_connections <<<'[]'
  "$BIN/omarchy-vpn-add" "$(ovpn_file)" "Office" || fail "add failed"
  "$BIN/omarchy-vpn-forget" "Office" "openvpn-client@Office" || fail "forget failed"
  assert_eq "$(jq -r 'length' "$OMARCHY_VPN_CONNECTIONS")" "0"
  [ -f "$SANDBOX/etc/openvpn/client/Office.conf" ] || fail "the file should have stayed"
}

test_forget_removes_file_when_asked() {
  write_connections <<<'[]'
  "$BIN/omarchy-vpn-add" "$(ovpn_file)" "Office" || fail "add failed"
  "$BIN/omarchy-vpn-forget" "Office" "openvpn-client@Office" --also-file || fail "forget failed"
  assert_eq "$(jq -r 'length' "$OMARCHY_VPN_CONNECTIONS")" "0"
  [ ! -e "$SANDBOX/etc/openvpn/client/Office.conf" ] || fail "the file is still there"
}

test_forget_asks_for_password_only_with_file() {
  write_connections <<<'[]'
  "$BIN/omarchy-vpn-add" "$(ovpn_file)" "Office" || fail "add failed"
  rm -f "$SANDBOX/pkexec.log"
  "$BIN/omarchy-vpn-forget" "Office" "openvpn-client@Office" || fail "forget failed"
  [ ! -e "$SANDBOX/pkexec.log" ] || fail "without --also-file no pkexec may run"
}

# The case the user tripped over, from beginning to end: create it, remove
# it via the cross WITHOUT "also delete the file", then pick
# the same file again. That used to end in "name already exists" and only
# 'sudo rm' helped. Now it resolves itself: the import accepts the
# byte-identical file without writing, and the list entry is created
# again.
test_add_recreates_entry_from_orphaned_file() {
  local src target before
  target="$SANDBOX/etc/openvpn/client/Office.conf"
  write_connections <<<'[]'
  src="$(ovpn_file)"
  "$BIN/omarchy-vpn-add" "$src" "Office" || fail "add failed"
  "$BIN/omarchy-vpn-forget" "Office" "openvpn-client@Office" || fail "forget failed"
  assert_eq "$(jq -r 'length' "$OMARCHY_VPN_CONNECTIONS")" "0"
  [ -f "$target" ] || fail "the file should have stayed behind -- otherwise the test checks nothing"
  before="$(file_fingerprint "$target")"

  "$BIN/omarchy-vpn-add" "$src" "Office" || fail "the second add should have succeeded"
  assert_eq "$(jq -r 'length' "$OMARCHY_VPN_CONNECTIONS")" "1"
  assert_eq "$(jq -r '.[0].unit' "$OMARCHY_VPN_CONNECTIONS")" "openvpn-client@Office"
  # And nothing was written in the process.
  assert_eq "$(file_fingerprint "$target")" "$before"
}

# The same dead end, but with a DIFFERENT file under the same label: that
# stays rejected -- and the message of the privileged program has to reach
# the user unchanged. It goes through 'tail -n1'; if it were lost or arrived
# truncated there, the user would be back in front of "name already exists"
# with no explanation.
test_add_passes_through_existing_file_message() {
  local rc=0 err src target before
  target="$SANDBOX/etc/openvpn/client/Office.conf"
  write_connections <<<'[]'
  "$BIN/omarchy-vpn-add" "$(ovpn_file)" "Office" || fail "add failed"
  "$BIN/omarchy-vpn-forget" "Office" "openvpn-client@Office" || fail "forget failed"
  before="$(file_fingerprint "$target")"

  src="$(ovpn_ok_variant | config_file "other.ovpn")"
  err="$("$BIN/omarchy-vpn-add" "$src" "Office" 2>&1 >/dev/null)" || rc=$?
  assert_eq "$rc" "14"
  assert_contains "$err" "with different content"
  assert_contains "$err" "also delete the file"
  assert_contains "$err" "pick a different label"
  assert_contains "$err" "sudo rm"
  # No list entry, and the existing file untouched.
  assert_eq "$(jq -r 'length' "$OMARCHY_VPN_CONNECTIONS")" "0"
  assert_eq "$(file_fingerprint "$target")" "$before"
  assert_eq "$(cat "$target")" "$(ovpn_ok)"
}

# Rework 2b: next to the tick has to stand what happens if it is NOT set.
# There is no QML test environment, so the source itself is pinned down --
# and at exactly the toggle in question (the line immediately after its
# label), not somewhere in the file. Without that anchoring the test would
# stay green even if the sentence stood in a completely different place.
#
# The label text is quoted VERBATIM in three English messages
# (share/omarchy-vpn-import, the comment in bin/omarchy-vpn-add, and the
# output of uninstall). If it is changed here, it has to be changed there
# as well -- otherwise those messages point at a button that does not exist
# under that name.
test_panel_remove_toggle_names_the_consequence() {
  local desc
  desc="$(grep -A1 -F 'label: "also delete the file"' \
          "$PLUGIN_DIR/Panel.qml" | tail -n1)"
  case "$desc" in
    *"description:"*) ;;
    *) fail "there is no description directly after the label" "found: $desc" ;;
  esac
  assert_contains "$desc" "Without the tick"
  assert_contains "$desc" "/etc"
  assert_contains "$desc" "no longer reachable"
}

test_forget_rejects_usage_errors() {
  local rc
  rc=0; "$BIN/omarchy-vpn-forget" >/dev/null 2>&1 || rc=$?; assert_eq "$rc" "1"
  rc=0; "$BIN/omarchy-vpn-forget" only-id >/dev/null 2>&1 || rc=$?; assert_eq "$rc" "1"
}

# The agreement test: the rules deliberately stand twice in the code (a
# privileged program sources nothing). This test is what holds them
# together -- if somebody adds a rule in only one of the two places, it
# turns red.
#
# Review I2: it was close to tautological. All payloads sat on the same
# OpenVPN base with one line appended -- no WireGuard, no <connection>, no
# indented configuration. Of all things, the ONE place where the two
# programs really did diverge (the detection line: inspect without, import
# with stripping of leading whitespace) was thus uncovered.
#
# And the expectation was too narrow: it rigidly demanded rc=71 (the rule
# table) for every rejection. A rejection from the DETECTION stage is 73
# and would have been wrongly reported as "inspect rejects, import
# accepts". Both codes are a rejection; the only distinction that matters
# is between "rejected" and "written".
agree_check() {
  local kind="$1" what="$2" payload="$3" ok rc
  ok="$(printf '%s\n' "$payload" | "$BIN/omarchy-vpn-inspect" | jq -r '.ok')"
  rc=0
  printf '%s\n' "$payload" | imp add "$kind" "Agreement" >/dev/null 2>&1 || rc=$?
  if [ "$ok" = "true" ]; then
    [ "$rc" = "0" ] || fail "inspect accepts, import rejects (rc=$rc) for: $what"
    [ -f "$SANDBOX/etc/openvpn/client/Agreement.conf" ] || \
      [ -f "$SANDBOX/etc/wireguard/Agreement.conf" ] || \
      fail "import reported success but wrote nothing for: $what"
  else
    case "$rc" in
      71|73) ;;
      0) fail "inspect rejects, import accepts for: $what" ;;
      *) fail "inspect rejects, import fails for a different reason (rc=$rc) for: $what" ;;
    esac
    [ ! -f "$SANDBOX/etc/openvpn/client/Agreement.conf" ] && \
      [ ! -f "$SANDBOX/etc/wireguard/Agreement.conf" ] || \
      fail "rejected, yet written for: $what"
  fi
  rm -f "$SANDBOX/etc/openvpn/client/Agreement.conf" "$SANDBOX/etc/wireguard/Agreement.conf"
}

test_inspect_and_import_agree() {
  local d payload
  for d in "" "ca ca.crt" "cert c.crt" "key k.key" "tls-auth ta.key 1" \
           "tls-crypt tc.key" "tls-crypt-v2 tc2.key" "dh dh.pem" \
           "pkcs12 c.p12" "secret s.key" "crl-verify crl.pem" \
           "config extra.conf" "auth-user-pass" "auth-user-pass z.txt" \
           "askpass" "askpass p.txt" "up /tmp/x" "down /tmp/x" "up-restart" \
           "route-up /tmp/x" "route-pre-down /tmp/x" "ipchange /tmp/x" \
           "client-connect /tmp/x" "client-disconnect /tmp/x" \
           "learn-address /tmp/x" "tls-verify /tmp/x" \
           "auth-user-pass-verify /tmp/x via-env" "plugin /tmp/x.so" \
           "script-security 2" "up-delay" "verb 3" \
           "--up /tmp/x" '"up" /tmp/x' "'up' /tmp/x" \
           "--script-security 2" 'u"p" /tmp/x' \
           "pkcs11-providers /tmp/x.so" "log /etc/hostname" \
           "log-append /etc/hostname" "status /etc/hostname" \
           "writepid /etc/hostname" "auth-gen-token-secret /etc/tok" \
           "capath /etc/ssl" "cd /etc" "chroot /etc" "client-config-dir /etc" \
           "extra-certs /etc/x.pem" "iproute /tmp/ip.sh" \
           "replay-persist /etc/hostname" "tls-crypt-v2-verify /tmp/v.sh" \
           "tls-export-cert /etc" "tmp-dir /etc" "dns-updown /tmp/x" \
           "http-proxy 10.0.0.1 3128" "http-proxy 10.0.0.1 3128 /etc/shadow" \
           "http-proxy 10.0.0.1 3128 /etc/shadow basic" \
           "socks-proxy 10.0.0.1" "socks-proxy 10.0.0.1 1080" \
           "socks-proxy 10.0.0.1 1080 /etc/shadow" \
           "http-proxy-user-pass /etc/shadow" "http-proxy-option AUTH none" \
           "dev-node unix:/tmp/prog" "dev-node /dev/net/tun" \
           "management 127.0.0.1 7505" "management-client" \
           "genkey secret /etc/x" "port-share 203.0.113.9 443" \
           "client-crresponse /tmp/x" "pkcs11-id-management" \
           "show-pkcs11-ids /tmp/evil.so" "ifconfig-pool-persist /etc/x" \
           "engine dynamic" "providers legacy" "register-dns" "win-sys env" \
           "setenv opt up /tmp/x" "setenv opt script-security 2" \
           "setenv opt ca /etc/shadow" "setenv OPT up /tmp/x" "setenv opt" \
           "setenv opt block-outside-dns" \
           "setenv-safe CUSTOMER example" \
           "daemon" "user nobody" "group nobody" "syslog vpn" "nice 5" \
           "echo hello" "mlock" "mode server" "server 10.8.0.0 255.255.255.0" \
           "tls-server" "multihome" "preresolve" \
           "fast-io" "keepalive 10 60" "mute-replay-warnings" \
           "auth-retry nointeract" "push-peer-info" "compat-mode 2.4.0" \
           "tls-groups X25519" "max-packet-size 1400" "disable-dco" \
           "route 10.20.0.0 255.255.0.0" "route-nopull" \
           "redirect-gateway def1" "dhcp-option DNS 10.20.0.53" \
           "--verb 3" '"'"'"verb" 3'"'"' "--persist-tun" \
           "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa xyz"; do
    if [ -z "$d" ]; then payload="$(ovpn_ok)"; else payload="$( { ovpn_ok; printf '%s\n' "$d"; } )"; fi
    agree_check openvpn "${d:-<no extra line>}" "$payload"
  done
}

# The payloads the old agreement test was missing (Review I2):
# WireGuard, <connection>, indentation, disguise. A separate test so that
# a failure shows at once which class is affected.
test_inspect_and_import_agree_beyond_the_flat_openvpn_case() {
  local d payload
  # WireGuard, benign and malicious -- the old test had not a single one.
  agree_check wireguard "wireguard <no extra line>" "$(wg_ok)"
  for d in "PostUp = /tmp/evil.sh" "PreUp = /tmp/evil.sh" \
           "PostDown = /tmp/evil.sh" "PreDown = /tmp/evil.sh" \
           "postup = /tmp/evil.sh" "DNS = 10.9.0.1"; do
    payload="$( { wg_ok; printf '%s\n' "$d"; } )"
    agree_check wireguard "wireguard + $d" "$payload"
  done
  # <connection> blocks, benign and malicious.
  agree_check openvpn "legitimate <connection> block" \
    "$(printf 'client\ndev tun\nproto tcp-client\n<connection>\nremote 198.51.100.10 1194 tcp\nconnect-retry 5\n</connection>\n')"
  agree_check openvpn "tls-auth in <connection>" \
    "$(printf 'client\ndev tun\nproto tcp-client\n<connection>\nremote 198.51.100.10 1194\ntls-auth /etc/hostname\n</connection>\n')"
  agree_check openvpn "http-proxy with auth file in <connection>" \
    "$(printf 'client\ndev tun\nproto tcp-client\n<connection>\nremote 198.51.100.10 1194\nhttp-proxy 203.0.113.9 8080 /etc/shadow basic\n</connection>\n')"
  agree_check openvpn "up in <connection>" \
    "$(printf 'client\ndev tun\nproto tcp-client\n<connection>\nremote 198.51.100.10 1194\nup /tmp/evil.sh\n</connection>\n')"
  # An indented detection line -- EXACTLY the divergence this test is meant
  # to rule out: inspect matched without stripping leading whitespace,
  # import with. The evidence was "  client\n  remote ..." with inspect
  # ok=false and import rc=0.
  agree_check openvpn "indented detection line" \
    "$(printf '  client\n  dev tun\n  remote 198.51.100.10 1194\n')"
  agree_check openvpn "indented detection line with a code directive" \
    "$(printf '  client\n  remote 198.51.100.10 1194\n  up /tmp/evil.sh\n')"
  agree_check openvpn "indented detection line with a tab" \
    "$(printf '\tclient\n\tremote 198.51.100.10 1194\n')"
  # Disguise: "[Interface]" inside a <ca> block (Review I1).
  agree_check openvpn "[Interface] disguise in <ca>" \
    "$(printf 'client\ndev tun\nremote 198.51.100.10 1194\nscript-security 2\nup /tmp/evil.sh\n<ca>\n[Interface]\nMIIExampleCA\n</ca>\n')"
  # Marker and inline cases (Review Critical and Important 1): exactly the
  # class in which the two programs used to be wrong together -- the
  # agreement test alone would never have found them. It stands here all
  # the same, because from now on the marker logic is duplicated in FOUR
  # places (check_openvpn and detect_kind, in each program) and that is
  # precisely the kind of duplication that drifts apart.
  agree_check openvpn "indented closing marker (tab)" \
    "$(printf 'client\ndev tun\nremote 198.51.100.10 1194\n<ca>\nMIIExampleCA\n\t</ca>\nup /tmp/evil.sh\n<cert>\nMIIExampleCert\n</cert>\n')"
  agree_check openvpn "indented closing marker (spaces)" \
    "$(printf 'client\ndev tun\nremote 198.51.100.10 1194\n<ca>\nMIIExampleCA\n  </ca>\nup /tmp/evil.sh\n<cert>\nMIIExampleCert\n</cert>\n')"
  agree_check openvpn "indented opening marker" \
    "$(printf 'client\ndev tun\nremote 198.51.100.10 1194\n\t<ca>\nMIIExampleCA\n\t</ca>\n')"
  agree_check openvpn "opening marker with trailing text" \
    "$(printf 'client\ndev tun\nremote 198.51.100.10 1194\n<ca> trailing\nup /tmp/evil.sh\n</ca>\n')"
  agree_check openvpn "closing marker with trailing text" \
    "$(printf 'client\ndev tun\nremote 198.51.100.10 1194\n<ca>\nMIIExampleCA\n</ca>x\nup /tmp/evil.sh\n')"
  for d in auth-user-pass http-proxy-user-pass auth-gen-token-secret secret \
           config log up plugin script-security dev-node management; do
    agree_check openvpn "inline block <$d>" \
      "$(printf 'client\ndev tun\nremote 198.51.100.10 1194\n<%s>\nhushhush\n</%s>\n' "$d" "$d")"
  done
  for d in ca cert key dh extra-certs pkcs12 crl-verify tls-auth tls-crypt \
           tls-crypt-v2 peer-fingerprint verify-hash; do
    agree_check openvpn "key block <$d>" \
      "$(printf 'client\ndev tun\nremote 198.51.100.10 1194\n<%s>\nup /tmp/evil.sh\n</%s>\n' "$d" "$d")"
  done
  agree_check openvpn "hook behind a fake marker" \
    "$(printf 'client\ndev tun\nremote 198.51.100.10 1194\n<ca> trailing\n[Interface]\nPostUp = /tmp/evil.sh\n</ca>\n')"
  # A cross-section of the stock of realistic provider configurations: they
  # are the only payloads here for which a failed agreement would mean that
  # a VALID configuration arrives at only one of the two programs. All nine
  # of them, not just one: the classes differ (indentation, <connection>,
  # embedded blocks, 'setenv opt', old and new directives).
  for d in $(stock_names); do
    agree_check openvpn "stock: $d" "$("stock_$d")"
  done
  # Nothing recognizable at all: both have to reject (inspect ok=false,
  # import 73) -- the case the old rigid rc=71 expectation would have
  # reported as a divergence.
  agree_check openvpn "unrecognizable input" "$(printf 'Hello world\nanother line\n')"
}

# --------------------------------------------------------- install tests
#
# 'install' really runs here, it is not simulated -- but harmlessly: it only
# calls chmod on the plugin's own files (chmod is deliberately not in the
# symlink farm above, so the call fails inside the sandbox and is swallowed
# by the '2>/dev/null' in the script -- without 'set -e' that does not stop
# anything), and it reads/writes nothing but the configuration file
# redirected through OMARCHY_VPN_CONNECTIONS inside the sandbox HOME.
# No systemctl, no omarchy-vpn-toggle.

# --- Second review round: four regression tests it asked for ------------

# 'setenv' set any environment variable for the root openvpn process --
# LD_PRELOAD among them, which loads attacker code into the executables
# openvpn itself invokes. Rejecting 'up' and 'plugin' while allowing this
# was a door beside the one we had locked. openvpn ships 'setenv-safe' for
# exactly this reason: it prefixes every name with OPENVPN_.
test_setenv_cannot_set_loader_variables() {
  local v
  for v in LD_PRELOAD LD_LIBRARY_PATH LD_AUDIT PATH IFS BASH_ENV FORWARD_COMPATIBLE; do
    local out
    out="$(printf 'client\nremote 192.0.2.1 1194\nsetenv %s /tmp/x\n' "$v" | inspect)"
    [ "$(printf '%s' "$out" | jq -r '.ok')" = "false" ] || \
      fail "setenv $v was accepted" "$out"
  done
}

# setenv-safe stays: it cannot name a loader variable, because openvpn
# prefixes what it sets.
test_setenv_safe_is_still_accepted() {
  local out
  out="$(printf 'client\nremote 192.0.2.1 1194\nsetenv-safe CUSTOMER example\n' | inspect)"
  assert_eq "$(printf '%s' "$out" | jq -r '.ok')" "true"
}

# ... and so does the one form commercial configurations really ship. It
# needs no exception: 'setenv opt' is a prefix openvpn strikes, so what is
# judged is 'block-outside-dns', which is on the allowlist in its own right.
test_setenv_opt_block_outside_dns_still_passes() {
  local out
  out="$(printf 'client\nremote 192.0.2.1 1194\nsetenv opt block-outside-dns\n' | inspect)"
  assert_eq "$(printf '%s' "$out" | jq -r '.ok')" "true"
}

# omarchy-vpn-add read the whole chosen file into a shell variable before
# either bounded program saw it. The bound belongs at the first boundary,
# not the second.
test_add_rejects_oversized_file() {
  local rc=0 err big
  big="$SANDBOX/huge.ovpn"
  head -c 1200000 /dev/zero | tr '\0' 'a' >"$big"
  err="$("$BIN/omarchy-vpn-add" "$big" "Huge" 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail "an oversized file was accepted"
  # "file too large" is omarchy-vpn-add's own wording. The importer says
  # "input too large" and inspect the same -- asserting on that would have
  # passed on the strength of a downstream bound while this program still
  # read the file whole, which is exactly what the review objected to.
  assert_contains "$err" "file too large"
  [ ! -e "$SANDBOX/etc/openvpn/client/Huge.conf" ] || fail "it was written anyway"
  # The message alone proves nothing: without a bound at the READ, cat still
  # pulls the whole file into the variable and the length check then reports
  # it just the same. A mutation probe showed exactly that. What the review
  # asked for is a bound on the read itself, so the bytes are never held.
  grep -q 'cat -- "$path" 2>/dev/null | head -c' "$BIN/omarchy-vpn-add" || \
    fail "the read in omarchy-vpn-add is not bounded -- only its result is checked"
}

# The connection list was read and parsed in full -- twice -- before the
# 200-entry cap applied. A corrupted or padded state file could exhaust the
# shell before the cap was ever reached.
test_list_refuses_an_oversized_state_file() {
  local out size
  # VALID JSON, deliberately: three megabytes of rubbish is refused for
  # being unparseable, which says nothing about a size bound. A mutation
  # probe showed exactly that -- the test passed with the bound removed.
  # This file parses fine and is merely too big.
  { printf '['
    for ((i=1; i<=4000; i++)); do
      [ "$i" -gt 1 ] && printf ','
      printf '{"id":"c%s","label":"padding-padding-padding-padding-%s","unit":"openvpn-client@c%s"}' "$i" "$i" "$i"
    done
    printf ']'
  } >"$OMARCHY_VPN_CONNECTIONS"
  size="$(stat -c %s "$OMARCHY_VPN_CONNECTIONS")"
  [ "$size" -gt 262144 ] || fail "the fixture is not over the bound at all ($size bytes)"
  printf '%s' "$(cat "$OMARCHY_VPN_CONNECTIONS")" | jq -e 'type == "array"' >/dev/null 2>&1 || \
    fail "the fixture is not valid JSON -- then this tests the wrong thing"

  out="$("$BIN/omarchy-vpn-list" --json 2>&1)"
  printf '%s' "$out" | jq -e 'type == "object" and has("error")' >/dev/null 2>&1 || \
    fail "an oversized but valid state file was parsed anyway" "$(printf '%s' "$out" | head -c 160)"

  # ... and an ordinary one still works, so the bound is a bound, not a wall.
  write_connections <<<'[{"id":"a","label":"a","unit":"openvpn-client@a"}]'
  out="$("$BIN/omarchy-vpn-list" --json 2>/dev/null)"
  assert_eq "$(printf '%s' "$out" | jq 'length')" "1"
}

# ... and the bytes that reach root have to be the bytes that were
# fingerprinted. The stub below makes the user side record a digest that
# does not describe what it sends, while root's own '-c' check runs for
# real -- which is exactly the shape of a payload swapped after the
# decision to install was taken.
test_install_system_refuses_a_substituted_payload() {
  seed_system_artefacts
  printf 'the previous helper\n' >"$OMARCHY_VPN_PRIVILEGED"
  cat >"$SANDBOX/stub/sha256sum" <<STUB
#!/usr/bin/env bash
# Verification ('-c') is the real thing; producing a digest is not.
for a in "\$@"; do [ "\$a" = "-c" ] && exec "$SANDBOX/sysbin/sha256sum" "\$@"; done
for f in "\$@"; do
  printf '%s  %s\n' "0000000000000000000000000000000000000000000000000000000000000000" "\$f"
done
STUB
  "$TEST_CHMOD" +x "$SANDBOX/stub/sha256sum"
  "$PLUGIN_DIR/install" --system >/dev/null 2>&1
  rm -f "$SANDBOX/stub/sha256sum"
  assert_eq "$(cat "$OMARCHY_VPN_PRIVILEGED")" "the previous helper"
}

# The privileged payload must be read ONCE. Reading it again at archive time
# reopens a mutable path after the decision to install was made.
test_install_system_reads_the_payload_once() {
  local body
  body="$(sed 's|#.*$||' "$PLUGIN_DIR/install")"
  case "$body" in
    *'tar -C "$DIR/share"'*)
      fail "the payload is archived straight from the checkout -- that is a second read" ;;
  esac
}

# --- Panel: what the security review asked for (finding 4) --------------
#
# "Panel collectors and process lifecycles are unbounded: list/inspect
# stdout and toggle/manage stderr are fully buffered; commands use
# PATH-resolved bash; no wall-clock/process-tree teardown exists; and list
# runtime is connections x SYSTEMCTL_TIMEOUT, both user-controlled."
#
# Three of these are structural and are held here by reading Panel.qml. The
# fourth -- the cardinality cap -- is behaviour and gets a real test below.

# A PATH-resolved interpreter is an invitation: whoever can put a 'bash'
# earlier in PATH decides what the panel runs.
test_panel_uses_no_path_resolved_interpreter() {
  local hits
  # Comments are stripped first: a comment explaining why a PATH-resolved
  # bash is wrong must not be what makes the test fail.
  hits="$(sed 's|//.*$||' "$PLUGIN_DIR/Panel.qml" | grep -n '"bash"' || true)"
  [ -z "$hits" ] || fail "the panel starts a PATH-resolved bash" "$hits"
}

# Every process the panel starts carries a wall-clock bound, so a command
# that never returns cannot pin the panel for ever.
test_panel_bounds_every_process_in_time() {
  local assigns unbounded
  # Every place that hands a command to a Process, whether as a property or
  # by assignment. Each one has to go through a runner -- that is where the
  # absolute interpreter and the wall-clock bound live.
  assigns="$(sed 's|//.*$||' "$PLUGIN_DIR/Panel.qml" | grep -cE 'command: |command = ')"
  [ "$assigns" -gt 0 ] || fail "no process commands found -- the test is looking at the wrong thing"
  unbounded="$(sed 's|//.*$||' "$PLUGIN_DIR/Panel.qml" \
               | grep -E 'command: |command = ' | grep -vc 'root.runner')"
  [ "$unbounded" = "0" ] || \
    fail "$unbounded of $assigns process commands bypass the runner" \
         "$(sed 's|//.*$||' "$PLUGIN_DIR/Panel.qml" | grep -E 'command: |command = ' | grep -v 'root.runner')"
}

# A panel that goes away must not leave processes running. The wall-clock
# bound would end them eventually, but that can be two minutes of work
# nobody is waiting for.
test_panel_stops_its_processes_on_destruction() {
  local block procs stopped
  block="$(sed -n '/Component.onDestruction/,/^  }/p' "$PLUGIN_DIR/Panel.qml")"
  [ -n "$block" ] || fail "the panel has no Component.onDestruction"
  procs="$(grep -c '^    id: [a-zA-Z]*Proc$' "$PLUGIN_DIR/Panel.qml")"
  stopped="$(printf '%s\n' "$block" | grep -c 'running = false')"
  [ "$procs" -gt 0 ] || fail "no processes found -- the test is looking at the wrong thing"
  assert_eq "$stopped" "$procs"
}

# And a bound on what a producer may hand back: a collector reads into
# memory, so the limit belongs on the producing side, not on the reader.
test_panel_bounds_what_producers_may_return() {
  local body
  body="$(cat "$PLUGIN_DIR/Panel.qml")"
  # The limit sits in the two runners that feed a collector, not at each
  # call site -- a limit that has to be remembered at every call is one that
  # gets forgotten at one of them. So: both helpers carry it ...
  case "$body" in
    *"function runnerOut"*) ;; *) fail "there is no runnerOut" ;;
  esac
  case "$body" in
    *"function runnerErr"*) ;; *) fail "there is no runnerErr" ;;
  esac
  local outdef errdef
  outdef="$(sed -n '/function runnerOut/,/^  }/p' "$PLUGIN_DIR/Panel.qml")"
  errdef="$(sed -n '/function runnerErr/,/^  }/p' "$PLUGIN_DIR/Panel.qml")"
  case "$outdef" in *"head -c"*) ;; *) fail "runnerOut does not bound its producer" "$outdef" ;; esac
  case "$errdef" in *"head -c"*) ;; *) fail "runnerErr does not bound its producer" "$errdef" ;; esac
  # ... and nothing collecting output uses the bare runner.
  local bare
  bare="$(sed 's|//.*$||' "$PLUGIN_DIR/Panel.qml" \
          | grep -E 'command: |command = ' | grep -c 'root.runner(' || true)"
  [ "$bare" = "0" ] || \
    fail "$bare command(s) use the unbounded runner although their output is collected"
}

# The list asks systemctl once per connection, each with its own timeout, so
# its runtime is connections x timeout -- and the connection list is written
# by the user. Beyond a sane count the rest is refused rather than queried.
test_list_caps_the_number_of_connections() {
  local many out n
  # A bash loop rather than seq: the exclusive PATH does not carry seq, and
  # a test that fails because a tool is missing has proved nothing.
  many="$(for ((i=1; i<=500; i++)); do
            printf '{"id":"c%s","label":"c%s","unit":"openvpn-client@c%s"}\n' "$i" "$i" "$i"
          done | jq -s '.')"
  printf '%s\n' "$many" >"$OMARCHY_VPN_CONNECTIONS"
  out="$("$BIN/omarchy-vpn-list" --json 2>/dev/null)"
  n="$(printf '%s' "$out" | jq 'length')"
  [ "$n" -le 200 ] || fail "the list returned $n entries -- no cap is in effect"
  [ "$n" -gt 0 ] || fail "the cap swallowed everything"
}

# The version in the footer is a SECOND copy of what manifest.json says --
# QML cannot reach the manifest (Omarchy's PluginRegistry is an instance,
# not a singleton), and reading the file at runtime would run entirely
# untested, since the suite barely touches Panel.qml.
#
# A duplicate is acceptable exactly as long as it cannot drift in silence.
# That is what this test is for: the copies under /usr/local/bin could rot
# for days because nothing compared them; this one turns red on the next
# run.
test_panel_version_matches_the_manifest() {
  local in_qml in_manifest
  in_qml="$(sed -n 's/.*readonly property string pluginVersion: "\([^"]*\)".*/\1/p' \
            "$PLUGIN_DIR/Panel.qml" | head -n1)"
  [ -n "$in_qml" ] || fail "Panel.qml declares no pluginVersion"
  in_manifest="$(jq -r '.version' "$PLUGIN_DIR/manifest.json")"
  assert_eq "$in_qml" "$in_manifest"
}

# ... and it has to be rendered, not merely declared.
test_panel_shows_the_version_in_the_footer() {
  grep -q 'text: "v" + root.pluginVersion' "$PLUGIN_DIR/Panel.qml" || \
    fail "the version is declared but nowhere displayed"
}

# WHERE it stands matters, and grep cannot tell. The line was once a sibling
# of panelColumn instead of its last child -- inside the ScrollView, which
# takes its FIRST child as the content and parks any further one at the
# origin. The version then appeared at the top right instead of the bottom,
# while the grep above stayed green.
#
# Counting braces naively is what caused it: braces inside strings and
# comments count too. This test strips both before counting, and so must
# anyone moving the block.
test_panel_version_sits_inside_the_scrolled_column() {
  local verdict
  verdict="$("$TEST_AWK" '
    { line = $0
      gsub(/"[^"]*"/, "\"\"", line)      # strings out
      sub(/\/\/.*$/, "", line)          # line comments out
      if (line ~ /id: panelColumn/) { inside = 1; depth = 1; next }
      if (!inside) next
      n = gsub(/\{/, "{", line); m = gsub(/\}/, "}", line)
      depth += n - m
      if ($0 ~ /text: "v" \+ root\.pluginVersion/) found = 1
      if (depth <= 0) { inside = 0 }
    }
    END { print (found ? "inside" : "outside") }
  ' "$PLUGIN_DIR/Panel.qml")"
  [ "$verdict" = "inside" ] || \
    fail "the version line is not inside panelColumn -- it would not render at the bottom"
}

# ---------------------------------------------- uninstall --system tests
#
# The counterpart to 'install --system'. Those four sudo rm commands were
# typed by hand three times in one day while testing on a second machine --
# the same kind of copying that produced two of the three mishaps there.

# Helper: puts the four privileged artefacts in place so there is something
# to remove.
seed_system_artefacts() {
  printf 'priv\n'   >"$OMARCHY_VPN_PRIVILEGED"
  printf 'import\n' >"$OMARCHY_VPN_IMPORT"
  printf 'policy\n' >"$OMARCHY_VPN_POLICY"
  printf '%s ALL=(root) NOPASSWD: %s\n' "$(id -un)" "$OMARCHY_VPN_PRIVILEGED" >"$OMARCHY_VPN_SUDOERS"
}

test_uninstall_system_removes_all_four() {
  seed_system_artefacts
  "$PLUGIN_DIR/uninstall" --system >/dev/null 2>&1
  [ ! -e "$OMARCHY_VPN_PRIVILEGED" ] || fail "the switching program is still there"
  [ ! -e "$OMARCHY_VPN_IMPORT" ]     || fail "the import program is still there"
  [ ! -e "$OMARCHY_VPN_POLICY" ]     || fail "the polkit action is still there"
  [ ! -e "$OMARCHY_VPN_SUDOERS" ]    || fail "the sudoers file is still there"
}

# The mirror image of the install contract, and for the same reason. Taking
# the program away first leaves a rule pointing at nothing -- the state in
# which a missing program presents itself as a missing permission. If the
# run is interrupted, it must not be interrupted INTO that state.
test_uninstall_system_removes_rule_before_program() {
  seed_system_artefacts
  "$PLUGIN_DIR/uninstall" --system >/dev/null 2>&1
  local sudoers_line priv_line
  # Only the removals are compared, not any sudo call: reading the sudoers
  # file to see whether it is ours legitimately happens first and names both
  # paths, and must not be mistaken for a removal.
  sudoers_line="$(grep -n "^rm .*$OMARCHY_VPN_SUDOERS" "$SANDBOX/sudo.log" | head -n1 | cut -d: -f1)"
  priv_line="$(grep -n "^rm .*$OMARCHY_VPN_PRIVILEGED" "$SANDBOX/sudo.log" | head -n1 | cut -d: -f1)"
  [ -n "$sudoers_line" ] || fail "the sudoers file was never removed" "$(cat "$SANDBOX/sudo.log")"
  [ -n "$priv_line" ]    || fail "the switching program was never removed" "$(cat "$SANDBOX/sudo.log")"
  [ "$sudoers_line" -lt "$priv_line" ] || \
    fail "the program was taken away before the rule that points at it" "$(cat "$SANDBOX/sudo.log")"
}

# A sudoers file we did not write is none of our business. Without this a
# mis-set path -- or a file somebody extended by hand -- would take other
# rules down with it.
test_uninstall_system_spares_a_foreign_sudoers_file() {
  seed_system_artefacts
  printf 'somebody ALL=(root) NOPASSWD: /usr/bin/somethingelse\n' >"$OMARCHY_VPN_SUDOERS"
  local out
  out="$("$PLUGIN_DIR/uninstall" --system 2>&1)"
  [ -e "$OMARCHY_VPN_SUDOERS" ] || fail "a foreign sudoers file was deleted"
  assert_contains "$out" "not written by this plugin"
}

# Repeatable: with nothing there it reports and removes nothing.
#
# The sandbox seeds the two helper programs and the polkit action itself, so
# they are cleared first -- otherwise this would not be testing an empty
# system but the sandbox's own furniture.
test_uninstall_system_is_idempotent() {
  local rc=0 out
  rm -f "$OMARCHY_VPN_PRIVILEGED" "$OMARCHY_VPN_IMPORT" "$OMARCHY_VPN_POLICY" "$OMARCHY_VPN_SUDOERS"
  out="$("$PLUGIN_DIR/uninstall" --system 2>&1)" || rc=$?
  assert_eq "$rc" "0"
  assert_contains "$out" "not there"
  [ ! -f "$SANDBOX/sudo.log" ] || fail "something was removed although nothing was there" "$(cat "$SANDBOX/sudo.log")"
}

# The connection list belongs to the user, not to the plugin -- under no
# circumstances is it removed along the way.
test_uninstall_system_keeps_the_connection_list() {
  seed_system_artefacts
  printf '[]\n' >"$OMARCHY_VPN_CONNECTIONS"
  "$PLUGIN_DIR/uninstall" --system >/dev/null 2>&1
  [ -f "$OMARCHY_VPN_CONNECTIONS" ] || fail "the connection list was removed"
}

test_uninstall_without_system_calls_no_sudo() {
  seed_system_artefacts
  "$PLUGIN_DIR/uninstall" >/dev/null 2>&1
  [ ! -f "$SANDBOX/sudo.log" ] || fail "plain uninstall called sudo" "$(cat "$SANDBOX/sudo.log")"
  [ -e "$OMARCHY_VPN_PRIVILEGED" ] || fail "plain uninstall removed something"
}

test_uninstall_rejects_unknown_argument() {
  local rc=0 out
  out="$("$PLUGIN_DIR/uninstall" --wat 2>&1)" || rc=$?
  assert_eq "$rc" "64"
  assert_contains "$out" "Usage"
}

# ------------------------------------------------ install --system tests
#
# './install --system' performs the four privileged steps that used to be
# copied by hand out of the README. Two of the three mishaps during the test
# installation on a second machine came from exactly that copying: one of
# four commands never ran, and the sudoers line existed in two spellings.
#
# In the sandbox nothing privileged happens: 'sudo' and 'visudo' are stubs,
# and all four target paths are redirected through the environment.

# The security review found the input unbounded at every boundary: the
# panel pipes a file into inspect, omarchy-vpn-add keeps the whole thing,
# and the privileged importer did content="$(cat)" before any size check.
# A configuration is a few kilobytes; anything past a megabyte is not one.
# The limit has to bite in BOTH programs independently -- the importer
# cannot rely on having been fed by our own panel.
test_inspect_rejects_oversized_input() {
  local out
  out="$(head -c 1200000 /dev/zero | tr '\0' 'a' | "$BIN/omarchy-vpn-inspect")"
  assert_eq "$(printf '%s' "$out" | jq -r '.ok')" "false"
  assert_contains "$(printf '%s' "$out" | jq -r '.error')" "too large"
}

test_import_rejects_oversized_input() {
  local rc=0 err
  err="$(head -c 1200000 /dev/zero | tr '\0' 'a' \
         | "$SANDBOX/priv/omarchy-vpn-import" add openvpn Big 2>&1)" || rc=$?
  assert_eq "$rc" "73"
  assert_contains "$err" "too large"
  [ ! -e "$SANDBOX/etc/openvpn/client/Big.conf" ] || fail "an oversized input was written anyway"
}

# ... and a configuration of ordinary size still passes, so the limit is a
# limit and not a wall.
test_inspect_accepts_a_normal_configuration() {
  local out
  out="$(ovpn_ok | "$BIN/omarchy-vpn-inspect")"
  assert_eq "$(printf '%s' "$out" | jq -r '.ok')" "true"
}

# --- What the marketplace security review asked for ---------------------
#
# The review found the privileged publication reopening user-writable state.
# Between "sudo visudo -c -f /tmp/x" and "sudo install /tmp/x", the file
# belongs to the user: a process under the same uid can swap it, and an
# arbitrary NOPASSWD rule gets installed. The detour through a scratch file
# guards against a TYPO, never against an attacker -- it created the window.
#
# The four tests below encode what replaced it. They are structural: they
# read what the program hands to sudo, because a race cannot be provoked
# reliably in a test suite. Structure is what can be held.

# One privileged invocation, not five. Every additional one is another
# moment in which the world can change between check and use.
test_install_system_elevates_exactly_once() {
  "$PLUGIN_DIR/install" --system >/dev/null 2>&1
  local n
  n="$(grep -c . "$SANDBOX/sudo.log" 2>/dev/null || echo 0)"
  [ "$n" = "1" ] || fail "expected a single sudo invocation, got $n" "$(cat "$SANDBOX/sudo.log")"
}

# Nothing under the plugin directory may be named to sudo. The reviewed
# bytes are handed over, not a path that root reopens afterwards -- the
# checkout is user-writable, so a path is an invitation to swap.
test_install_system_hands_root_no_plugin_path() {
  "$PLUGIN_DIR/install" --system >/dev/null 2>&1
  if grep -q -- "$PLUGIN_DIR" "$SANDBOX/sudo.log" 2>/dev/null; then
    fail "a path inside the plugin directory was passed to sudo" "$(cat "$SANDBOX/sudo.log")"
  fi
}

# The sudoers subject is the numeric uid. A login name is text that sudoers
# interprets: an account called 'ALL' would change what the rule means.
test_install_system_binds_the_numeric_uid() {
  "$PLUGIN_DIR/install" --system >/dev/null 2>&1
  [ -f "$OMARCHY_VPN_SUDOERS" ] || fail "no sudoers file was written"
  local body; body="$(cat "$OMARCHY_VPN_SUDOERS")"
  case "$body" in
    "#$(id -u) ALL=(root) NOPASSWD: "*) ;;
    *) fail "the rule does not bind the numeric uid" "$body" ;;
  esac
  case "$body" in
    *"$(id -un)"*) fail "the login name appears in the rule" "$body" ;;
  esac
}

# If the grant cannot be published, what was already replaced goes back.
# Otherwise an interrupted run leaves a half-updated privileged program
# behind with no rule, or an old rule pointing at a new binary.
test_install_system_rolls_back_when_the_grant_fails() {
  seed_system_artefacts
  printf 'the previous helper\n' >"$OMARCHY_VPN_PRIVILEGED"
  printf 'the previous importer\n' >"$OMARCHY_VPN_IMPORT"
  # The grant must fail AFTER publication has begun, not before. Letting
  # visudo reject the rule aborts ahead of the first write, so nothing needs
  # undoing and the test would pass without a rollback existing at all --
  # which is exactly what a mutation probe caught. An unreachable
  # destination fails at the last of the four writes instead.
  export OMARCHY_VPN_SUDOERS="$SANDBOX/no-such-dir/smartalb-vpn"
  "$PLUGIN_DIR/install" --system >/dev/null 2>&1
  [ ! -e "$OMARCHY_VPN_SUDOERS" ] || fail "the grant was published although its directory is missing"
  assert_eq "$(cat "$OMARCHY_VPN_PRIVILEGED")" "the previous helper"
  assert_eq "$(cat "$OMARCHY_VPN_IMPORT")" "the previous importer"
}

# The order is a contract, not a preference. If the sudoers file goes in
# first and installing the program then fails, a rule stands that points at
# nothing -- and that is exactly the state which cost an hour on the laptop,
# because sudo does not treat a rule whose program it cannot resolve as
# matching, so a missing program looks like a missing permission.
test_install_system_installs_program_before_sudoers_rule() {
  local out priv_line rule_line
  out="$("$PLUGIN_DIR/install" --system 2>&1)"
  # Measured on what the program reports, not on how it called sudo: there
  # is only one call now, and the order lives inside it.
  priv_line="$(printf '%s\n' "$out" | grep -n "installing $OMARCHY_VPN_PRIVILEGED\$" | head -n1 | cut -d: -f1)"
  rule_line="$(printf '%s\n' "$out" | grep -n "installing $OMARCHY_VPN_SUDOERS\$" | head -n1 | cut -d: -f1)"
  [ -n "$priv_line" ] || fail "the switching program was never installed" "$out"
  [ -n "$rule_line" ] || fail "the sudoers rule was never installed" "$out"
  [ "$priv_line" -lt "$rule_line" ] || \
    fail "the sudoers rule was put in place before the program it points at" "$out"
}

# A rejected sudoers file must not reach its destination -- that is the whole
# reason for the detour through a temporary file.
test_install_system_keeps_rejected_sudoers_out() {
  local rc=0
  : >"$SANDBOX/visudo-rejects"
  "$PLUGIN_DIR/install" --system >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "a rejected sudoers file was reported as success"
  [ ! -f "$OMARCHY_VPN_SUDOERS" ] ||     fail "the rejected file was put into place anyway" "$(cat "$OMARCHY_VPN_SUDOERS")"
}

# ... and it must not leave its scratch file behind either.
#
# The scratch path is not guessed here -- it is read back out of the sudo
# log. Searching /tmp for a name of my own invention would keep this test
# green for ever if the implementation chose a different one; this way the
# test fails when no scratch file is written at all.
test_install_system_leaves_no_scratch_file_after_rejection() {
  : >"$SANDBOX/visudo-rejects"
  "$PLUGIN_DIR/install" --system >/dev/null 2>&1
  local scratch
  # The path is read back out of the visudo log rather than guessed. Under
  # the old shape it lay in the user's /tmp and could be swapped between the
  # check and the install; it now lives in root's own staging directory and
  # has to be gone afterwards either way.
  scratch="$(sed -n 's/.*-f \(\/[^ ]*\).*/\1/p' "$SANDBOX/visudo.log" 2>/dev/null | head -n1)"
  [ -n "$scratch" ] || \
    fail "visudo was never handed a file -- the check was skipped" \
         "$(cat "$SANDBOX/visudo.log" 2>/dev/null)"
  [ ! -e "$scratch" ] || fail "the staged file was left behind" "$scratch"
}

# Repeatable: a second run over an unchanged system installs nothing again.
# This is what makes the command usable as the routine after a plugin update.
test_install_system_is_idempotent() {
  "$PLUGIN_DIR/install" --system >/dev/null 2>&1
  local out
  out="$("$PLUGIN_DIR/install" --system 2>&1)"
  case "$out" in
    *"installing $OMARCHY_VPN_PRIVILEGED"*)
      fail "an unchanged program was installed a second time" "$out" ;;
  esac
  assert_contains "$out" "already current"
}

# The mirror image: an outdated copy IS replaced. Without this the command
# would be useless for exactly the case it exists for.
test_install_system_replaces_an_outdated_copy() {
  "$PLUGIN_DIR/install" --system >/dev/null 2>&1
  printf 'stale\n' >"$OMARCHY_VPN_PRIVILEGED"
  : >"$SANDBOX/sudo.log"
  "$PLUGIN_DIR/install" --system >/dev/null 2>&1
  grep -q "omarchy-vpn-privileged" "$SANDBOX/sudo.log" ||     fail "an outdated copy was not replaced" "$(cat "$SANDBOX/sudo.log")"
  cmp -s "$PLUGIN_DIR/share/omarchy-vpn-privileged" "$OMARCHY_VPN_PRIVILEGED" ||     fail "after replacing, the copy still differs from the source"
}

# Without --system nothing privileged happens. './install' has to stay the
# harmless check that the README says it is.
test_install_without_system_calls_no_sudo() {
  "$PLUGIN_DIR/install" >/dev/null 2>&1
  [ ! -f "$SANDBOX/sudo.log" ] || fail "plain install called sudo" "$(cat "$SANDBOX/sudo.log")"
  [ ! -f "$SANDBOX/visudo.log" ] || fail "plain install called visudo"
}

# Run as root the line would name root instead of the real user -- a rule
# that grants nothing to the person who is supposed to switch.
test_install_system_refuses_to_run_as_root() {
  local rc=0 out
  out="$(FAKE_EUID=0 "$PLUGIN_DIR/install" --system 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail "install --system accepted being run as root"
  assert_contains "$out" "not as root"
  [ ! -f "$SANDBOX/sudo.log" ] || fail "something was installed despite the refusal"
}

test_install_rejects_unknown_argument() {
  local rc=0 out
  out="$("$PLUGIN_DIR/install" --wat 2>&1)" || rc=$?
  assert_eq "$rc" "64"
  assert_contains "$out" "Usage"
}

test_install_reports_valid_config_unchanged() {
  local out
  out="$("$PLUGIN_DIR/install")"
  assert_contains "$out" "left unchanged"
  case "$out" in
    *WARNING*invalid*) fail "a valid configuration should not have triggered an invalid warning" ;;
  esac
  assert_eq "$(jq -r 'length' "$OMARCHY_VPN_CONNECTIONS")" "3"
}

# Shows point 3: a configuration that is present but broken (not valid
# JSON) must no longer be waved through by 'install' as "present, left
# unchanged" -- until now the user just saw an empty popup later and went
# looking in the wrong place. The file itself stays untouched, it is the
# user's configuration.
# Review I3: "WARNING" alone checks NOTHING here -- inside the sandbox the
# warnings about the switching program fire anyway (see the comment at the
# install tests). Evidence: set the jq condition in install to 'true', i.e.
# switch off the whole configuration validation, and all three tests stayed
# green. What is checked is therefore the EXACT warning AND the absence of
# the success message -- as in test_install_warns_when_import_helper_missing.
test_install_warns_about_broken_json_and_keeps_it() {
  local out
  printf 'not json' >"$OMARCHY_VPN_CONNECTIONS"
  out="$("$PLUGIN_DIR/install")"
  assert_contains "$out" "WARNING: configuration present, but invalid"
  assert_contains "$out" "$OMARCHY_VPN_CONNECTIONS"
  case "$out" in
    *"left unchanged"*) fail "a broken file should not have been waved through as unchanged" "$out" ;;
  esac
  assert_eq "$(cat "$OMARCHY_VPN_CONNECTIONS")" "not json"
}

# The same criterion as read_connections(): valid JSON that is not an array
# has to warn just as much, instead of counting as unchanged without a
# word.
test_install_warns_about_non_array_config_and_keeps_it() {
  local out
  printf '{"not":"array"}' >"$OMARCHY_VPN_CONNECTIONS"
  out="$("$PLUGIN_DIR/install")"
  assert_contains "$out" "WARNING: configuration present, but invalid"
  case "$out" in
    *"left unchanged"*) fail "valid JSON that is not an array should not have been waved through" "$out" ;;
  esac
  assert_eq "$(cat "$OMARCHY_VPN_CONNECTIONS")" '{"not":"array"}'
}

# The same criterion as read_connections(): an array element that is not an
# object invalidates the whole file (see review I3).
test_install_warns_about_non_object_element_and_keeps_it() {
  local out orig
  orig='[{"id":"a"}, "broken"]'
  printf '%s' "$orig" >"$OMARCHY_VPN_CONNECTIONS"
  out="$("$PLUGIN_DIR/install")"
  assert_contains "$out" "WARNING: configuration present, but invalid"
  case "$out" in
    *"left unchanged"*) fail "a non-object in the array should not have been waved through" "$out" ;;
  esac
  assert_eq "$(cat "$OMARCHY_VPN_CONNECTIONS")" "$orig"
}

# The heart of the abstraction: a stranger is no longer served somebody
# else's connections. install used to create example-29, example-26 and wg-home
# -- units that do not exist on their machine, so three dead entries on the
# first look into the panel.
test_install_creates_empty_config_when_missing() {
  local out
  rm -f "$OMARCHY_VPN_CONNECTIONS"
  out="$("$PLUGIN_DIR/install")"
  assert_contains "$out" "Configuration created"
  assert_eq "$(jq -r 'length' "$OMARCHY_VPN_CONNECTIONS")" "0"
  jq -e 'type == "array"' "$OMARCHY_VPN_CONNECTIONS" >/dev/null || fail "not an array"
}

# "WARNING" alone checks nothing: inside the sandbox the warnings about the
# switching program (cmp mismatch, stat != root 755) fire anyway, see
# test_install_warns_about_outdated_helper and
# test_install_warns_about_writable_helper_directory. And "omarchy-vpn-import"
# alone checks nothing either: the program name also appears in the success
# message "Import helper program present: .../omarchy-vpn-import". Without
# the exact message AND the absence of the success message the test would
# stay green even if install replaced [ -x "$IMPORT" ] with [ -n "$IMPORT" ]
# -- a non-existent path is not an empty string, so it would wrongly pass as
# present. The mirror image of test_install_confirms_installed_import_helper.
test_install_warns_when_import_helper_missing() {
  local out
  export OMARCHY_VPN_IMPORT="$SANDBOX/doesnotexist/omarchy-vpn-import"
  out="$("$PLUGIN_DIR/install")"
  assert_contains "$out" "WARNING: import helper program missing"
  case "$out" in
    *"Import helper program present"*) fail "should not have been reported as present" ;;
  esac
}

test_install_confirms_installed_import_helper() {
  local out
  out="$("$PLUGIN_DIR/install")"
  assert_contains "$out" "Import helper program present"
  case "$out" in
    *"WARNING: import helper program missing"*) fail "there should have been no warning" ;;
  esac
}

# Fix round 1: since setup_sandbox() OMARCHY_VPN_POLICY points at a sandbox
# file ($SANDBOX/polkit-actions/...) instead of the real polkit action under
# /usr/share/polkit-1/actions/ -- without that redirection this branch would
# have depended on the particular test machine, not been tested.
test_install_confirms_polkit_action_present() {
  local out
  out="$("$PLUGIN_DIR/install")"
  case "$out" in
    *"WARNING: polkit action missing"*) fail "an action that is present should not have been complained about" ;;
  esac
}

# install makes the plugin's own programs executable. It used to do that
# with a blanket 'chmod +x share/*' -- which also caught
# omarchy-vpn-import.policy, an XML file that polkit reads and nobody
# executes. Harmless in effect, but every installation then carried a
# permanent modification against its own git checkout, and that noise once
# made a real "are there local changes worth keeping?" check ambiguous.
#
# This test needs a real chmod, which the exclusive PATH deliberately does
# not have (see the comment at the install tests). It therefore runs a COPY
# of the plugin with TEST_CHMOD reachable, so the repository itself is never
# touched.
test_install_makes_only_programs_executable() {
  local copy chmoddir
  copy="$SANDBOX/plugin-copy"
  "$TEST_CP" -a "$PLUGIN_DIR" "$copy" || fail "could not copy the plugin"
  "$TEST_CHMOD" 644 "$copy/share/omarchy-vpn-privileged" "$copy/share/omarchy-vpn-import" \
                    "$copy/share/omarchy-vpn-import.policy" || fail "could not prepare permissions"

  chmoddir="$SANDBOX/with-chmod"
  mkdir -p "$chmoddir"
  ln -sf "$TEST_CHMOD" "$chmoddir/chmod"
  PATH="$chmoddir:$PATH" "$copy/install" >/dev/null 2>&1

  [ -x "$copy/share/omarchy-vpn-privileged" ] || fail "the switching program did not become executable"
  [ -x "$copy/share/omarchy-vpn-import" ]     || fail "the import program did not become executable"
  if [ -x "$copy/share/omarchy-vpn-import.policy" ]; then
    fail "the polkit action was made executable -- it is data, not a program"
  fi
}

test_install_warns_when_polkit_action_missing() {
  local out
  export OMARCHY_VPN_POLICY="$SANDBOX/doesnotexist/org.omarchy.smartalbvpn.import.policy"
  out="$("$PLUGIN_DIR/install")"
  assert_contains "$out" "WARNING: polkit action missing"
  assert_contains "$out" "$SANDBOX/doesnotexist/org.omarchy.smartalbvpn.import.policy"
}

# The installer cannot probe passwordless sudo harmlessly (see the README),
# but whether the helper program is installed at all can be answered without
# executing anything.
# Review I4: "WARNING" and "omarchy-vpn-privileged" both check nothing --
# the one fires inside the sandbox anyway, the other also appears in the
# instructions of the good case. Evidence: 'install' changed from
# [ -x "$PRIV" ] to [ -n "$PRIV" ] -- a non-existent helper counts as
# present -- and the test stayed green. Exactly the bug that task 6 fixed
# for the import program. What is checked is therefore the exact warning AND
# the absence of the success message WITH THE PATH ("helper program present"
# alone also occurs inside "Import helper program present", which is printed
# here every time).
test_install_warns_when_helper_missing() {
  local out
  export OMARCHY_VPN_PRIVILEGED="$SANDBOX/doesnotexist/omarchy-vpn-privileged"
  out="$("$PLUGIN_DIR/install")"
  assert_contains "$out" "WARNING: helper program missing: $SANDBOX/doesnotexist/omarchy-vpn-privileged"
  case "$out" in
    *"Helper program present: $SANDBOX/doesnotexist/omarchy-vpn-privileged"*)
      fail "a helper that does not exist should not have been reported as present" "$out" ;;
  esac
}

test_install_confirms_installed_helper() {
  local out
  # The default copy from setup_sandbox ($SANDBOX/priv) is deliberately
  # bent (SYSTEMCTL points at the stub, see there) -- against the real
  # share/omarchy-vpn-privileged the new cmp check in 'install' would ALWAYS
  # differ here, and this test would never check the actual good case
  # (contents agree) but only slip through by accident, because it never
  # looks at the mismatch case at all. Hence the redirection to the second,
  # unmodified copy in $SANDBOX/priv-installed -- see setup_sandbox().
  export OMARCHY_VPN_PRIVILEGED="$SANDBOX/priv-installed/omarchy-vpn-privileged"
  out="$("$PLUGIN_DIR/install")"
  # Review I4: WITH THE PATH -- "helper program present" alone also occurs
  # inside "Import helper program present: ...", which is printed on every
  # install run in this sandbox. Otherwise the test would only check that
  # the IMPORT helper is there and would say nothing at all about the
  # switching program.
  assert_contains "$out" "Helper program present: $OMARCHY_VPN_PRIVILEGED"
  case "$out" in
    *"WARNING: helper program missing"*) fail "there should have been no warning (missing)" ;;
  esac
  case "$out" in
    *"differs from the shipped"*) fail "a copy identical in content should not have triggered a difference warning" "$out" ;;
  esac
  # The owner/permissions warning and the directory warning are
  # deliberately NOT checked for absence here: the sandbox copy belongs to
  # the test user, never to root, and $SANDBOX is writable for them --
  # neither can be made "correct" without root. See the report.
}

# Shows the first part of important 1: an installed copy whose contents
# differ (e.g. after a plugin update without a repeated installation) has to
# be warned about, with a hint to repeat the install command. The default
# copy from setup_sandbox serves directly for that: it is deliberately bent
# and therefore guaranteed to differ in content from the shipped
# share/omarchy-vpn-privileged.
test_install_warns_about_outdated_helper() {
  local out
  out="$("$PLUGIN_DIR/install")"
  assert_contains "$out" "WARNING"
  assert_contains "$out" "differs from the shipped"
  assert_contains "$out" "Repeat the install command"
}

# Shows the second part of important 1, as far as that can be reproduced
# without root: a copy with the wrong permissions is complained about.
# Inside the sandbox only the permissions side can be set wrong on purpose
# (chmod 744 instead of 755) -- the owner here is always the test user,
# never root, and that cannot be arranged without root. Both criteria hang
# on the same check in 'install' (stat "%U %a" against "root 755"), so they
# fire together; isolating "only the permissions wrong, but the owner
# right" is fundamentally impossible inside the sandbox.
test_install_warns_about_wrong_permissions() {
  local out
  export OMARCHY_VPN_PRIVILEGED="$SANDBOX/priv-installed/omarchy-vpn-privileged"
  "$TEST_CHMOD" 744 "$OMARCHY_VPN_PRIVILEGED"
  out="$("$PLUGIN_DIR/install")"
  assert_contains "$out" "WARNING"
  assert_contains "$out" "not owned by root with mode 755"
}

# Shows the third part of important 1: a target directory writable for the
# user is complained about. Inside the sandbox that can only be checked as
# "it warns", never as "it does NOT warn" -- $SANDBOX belongs to the test
# user, every directory inside it is writable for them, and a root-owned
# directory not writable for them cannot be arranged without root. This
# check therefore fires along in EVERY install test of this suite; the other
# tests deliberately do not check for its absence.
test_install_warns_about_writable_helper_directory() {
  local out
  export OMARCHY_VPN_PRIVILEGED="$SANDBOX/priv-installed/omarchy-vpn-privileged"
  out="$("$PLUGIN_DIR/install")"
  assert_contains "$out" "WARNING"
  # Not merely "writable" -- inside the sandbox the permissions warning on
  # $PRIV delivers that too (never root:755 for the test user). This
  # substring comes from nowhere in install but the -w check on $PRIVDIR.
  assert_contains "$out" "is writable for this user"
}

# --------------------------------------------------------------- Runner

# An optional argument narrows the run to matching test names -- useful when
# one test is being worked on and the other two hundred are noise.
#   ./test/run-tests.sh install_system
main() {
  local t pattern="${1:-}"
  for t in $(declare -F | awk '{print $3}' | grep '^test_' | sort); do
    [ -z "$pattern" ] || case "$t" in *"$pattern"*) ;; *) continue ;; esac
    run_test "$t"
  done
  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
}

main "$@"
