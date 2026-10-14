# Security policy

ssh-fleet sits between you and your servers, so security problems in it matter
more than ordinary bugs. Thank you for reporting them responsibly.

## Supported versions

Security fixes go into the latest release and `main`. There are no long-term
support branches.

## Reporting a vulnerability

**Do not open a public issue.** Report it privately through GitHub instead:

1. Go to the repository's **Security** tab.
2. Choose **Report a vulnerability**.
3. Describe the problem, its impact, and how to reproduce it — using RFC 5737
   documentation addresses and invented host names, never real infrastructure.

You can expect an acknowledgement within a week. Once a fix is ready it will be
released, and the advisory published with credit to you unless you prefer to
stay anonymous.

## What counts as a vulnerability

Examples of what this policy covers:

- a tool sending a secret (password, passphrase) somewhere it can be read:
  `argv`, the environment of an unrelated process, a file, shell history, logs;
- `ssh-pass` answering a host-key confirmation prompt, or answering a prompt
  for the wrong host;
- a tool contacting or writing to a server without listing it and asking first;
- `ssh-manage` or `install.sh` leaving `~/.ssh` with unsafe permissions, or
  following a path outside it;
- example configuration that weakens a security default fleet-wide (for
  instance a `Host *` that enables agent forwarding or disables host-key
  checking).

Out of scope: weaknesses in OpenSSH itself (report those to the
[OpenSSH project](https://www.openssh.com/security.html)), and risks that the
README already documents as deliberate trade-offs — for example, that a
fleet-wide saved password is only as safe as your unlocked desktop session.
