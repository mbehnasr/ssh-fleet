# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-10-14

First public release.

### Added

- Multi-environment layout: `config` with workstation-wide defaults read last,
  `config.d/<env>.conf` per environment, `00-local.conf` untracked overrides.
- Example environments in `examples/config.d/` (RFC 5737 addresses): key auth
  with two network zones behind a bastion, password auth with host metadata,
  and a strict production setup.
- Tools: `install.sh`, `check.sh`, `ssh-hosts`, `ssh-menu`, `ssh-find`,
  `ssh-manage`, `ssh-tmux`, `ssh-pass` / `ssh-askpass`, `deploy-key.sh`,
  `migrate-known-hosts.sh`.
- Tests: `tests/smoke.sh`, `tests/e2e.sh`, and `tests/check-no-private-data.sh`,
  which rejects non-documentation IPv4 addresses, private keys and any term
  listed in a local `.private-terms` file.
- CI (shellcheck, privacy check, smoke and end-to-end tests), contribution
  guide, security policy, issue and pull request templates.

### Fixed

- `ssh-manage` checked only the first config file for an existing alias, so a
  duplicate alias could be added and then silently shadowed by
  first-match-wins; `rm-host` listed and verified against the same single file.
- `ssh-manage rm-env` exited with status 1 after a successful removal when no
  `known_hosts.d` file existed for the environment.
- `check.sh` no longer warns about two aliases sharing an address when their
  logins differ (a shell alias next to a `git@` alias is deliberate).
- `install.sh` verifies the first alias it finds instead of one hard-coded host.
- Documented OpenSSH minimum corrected to 9.4: the `Tag` keyword used in every
  environment file is rejected by older clients.

[Unreleased]: https://github.com/mbehnasr/ssh-fleet/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/mbehnasr/ssh-fleet/releases/tag/v0.1.0
