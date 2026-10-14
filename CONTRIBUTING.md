# Contributing

Thanks for taking the time to improve ssh-fleet. Bug reports, documentation
fixes, new tools from the [roadmap](ROADMAP.md) and portability fixes are all
welcome.

## The one rule: no real infrastructure data

This project exists to manage private networks, so it is easy to leak one by
accident. In issues, pull requests, commit messages, test fixtures and
screenshots:

- use only the RFC 5737 documentation ranges — `192.0.2.0/24`,
  `198.51.100.0/24`, `203.0.113.0/24` — and invented host names, as the
  [`examples/`](examples/config.d) do;
- never include real addresses, host or domain names, account names, key
  material, passphrases or passwords — redact `ssh -vvv` and `ssh -G` output
  before pasting it;
- run `tests/check-no-private-data.sh` before you push. CI runs it too, and
  fails on any non-documentation IPv4 address or private key block.

To catch your own organisation's names as well, copy `.private-terms.example`
to `.private-terms` (gitignored) and list them there.

## Development setup

You need the dependencies from [INSTALL.md](INSTALL.md), plus
[shellcheck](https://www.shellcheck.net/) for linting.

```bash
make lint       # shellcheck + a syntax check of ssh-pass
make privacy    # tests/check-no-private-data.sh
make test       # tests/smoke.sh: the example fleet in a throwaway SSH_DIR
```

None of these touch `~/.ssh` or open a network connection.

`tests/e2e.sh` performs a real install and exercises every write path
(`install.sh`, `ssh-manage`, `deploy-key.sh --dry-run`). Because it replaces
`~/.ssh/config`, it refuses to run unless `SSH_FLEET_E2E=1` is set, and should
only run somewhere disposable:

```bash
make e2e-container                      # in an ubuntu:24.04 container (needs Docker)
```

or, without Docker, with [bubblewrap](https://github.com/containers/bubblewrap)
mounting scratch directories over `~/.ssh` and `/tmp` for that one process:

```bash
d=$(mktemp -d); mkdir "$d/ssh" "$d/tmp"; : > "$d/ssh_config"
bwrap --dev-bind / / --bind "$d/ssh" "$HOME/.ssh" --bind "$d/tmp" /tmp \
      --ro-bind "$d/ssh_config" /etc/ssh/ssh_config \
      -- env SSH_FLEET_E2E=1 tests/e2e.sh
```

(The empty `ssh_config` is needed because root-owned system files appear with
an unmapped owner inside the namespace, and ssh refuses them.)

CI runs lint, the privacy check, the smoke test and the end-to-end test on every
push and pull request.

## Code style

- **Shell:** bash, `set -uo pipefail` (plus `-e` where every failure should
  abort), 4-space indentation, `shellcheck -S warning` clean. Quote every
  expansion. Prefer the patterns the existing scripts already use.
- **Comments explain why**, not what. Many lines in this repo exist because of
  a specific OpenSSH or terminal behaviour; say which one, so nobody "cleans it
  up" later.
- **Safety properties are features.** Changes must keep them: never write to a
  server without listing the targets and asking; back up before editing config
  and roll back if `ssh -G` rejects the result; never auto-answer a host-key
  prompt; never put a secret in `argv`, a file in the repo, or shell history.
- **Read the config, not a second inventory.** Tools derive everything from
  `config.d/*.conf` (via `ssh -G` or `scripts/lib/fleet-index.awk`), so the SSH
  config stays the single source of truth.
- Update README.md (reference) or INSTALL.md (setup) together with any
  behaviour change, and add an entry under *Unreleased* in
  [CHANGELOG.md](CHANGELOG.md).

## Pull requests

1. Fork, and create a branch from `main`.
2. Keep each PR to one logical change, with a test where it is practical —
   `tests/smoke.sh` for read-only behaviour, `tests/e2e.sh` for anything that
   writes.
3. Make sure `make lint privacy test` passes.
4. Describe *why* the change is needed, and how you tested it.

By contributing you agree that your contribution is licensed under the
[MIT License](LICENSE) of this project.

## Reporting security issues

Please do **not** open a public issue for a vulnerability — see
[SECURITY.md](SECURITY.md).
