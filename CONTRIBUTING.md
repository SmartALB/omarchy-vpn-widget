# Contributing

Thanks for looking. Suggestions, bug reports and questions are welcome --
please raise them as **issues**.

## Pull requests are not accepted

Not out of unfriendliness: this repository is a published snapshot of a
working repository kept elsewhere. Releases are exported over it wholesale,
so a merged patch would be overwritten by the next release without a
conflict and without a warning. Rather than lose your work quietly, the
project does not take patches at all.

## What helps instead

Open an issue. Concretely useful:

- **A bug**: what you did, what happened, what you expected. The output of
  `journalctl -u openvpn-client@<name>` or `journalctl -u wg-quick@<name>`
  usually names the cause, and in the panel every failure looks the same --
  `failed`.
- **A configuration that is rejected**: the message and the directive it
  names. The check is an allowlist, so a legitimate directive missing from
  it is a real gap. Please do not paste the configuration itself -- it
  carries keys.
- **A suggestion**: what you want to do and why the current way does not
  serve it. Patches are not accepted, but reasoning is read carefully.

The version is shown at the bottom of the panel; please include it.

## Scope

The plugin covers connections you run yourself, authenticating by
certificate or key. Configurations that log in with a user name and
password are rejected deliberately, so most commercial providers are out of
scope -- see the README introduction for the reasoning. A request to widen
that is a question about the security model, not a small feature, and is
best raised as an issue before any work.
