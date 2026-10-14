# Install

ssh-fleet is a portable SSH workstation setup: an `~/.ssh` layout built on
OpenSSH's `Include`, plus a small set of tools for browsing, editing and
operating a multi-environment server fleet.

Nothing here talks to the Internet or to any cloud service. It works fully
air-gapped.

---

## 1. Dependencies

### Required

| Dependency | Minimum | Why | Ubuntu/Debian package |
|---|---|---|---|
| **OpenSSH client** | **9.4** | `Include`, `ProxyJump`, `SSH_ASKPASS_REQUIRE`, and the `Tag` keyword in every environment file | `openssh-client` |
| **bash** | 4.3 | scripts use `mapfile`, namerefs, associative arrays | `bash` |
| **GNU coreutils** | any | `sort -V`, `stat -c`, `tac`, `paste`, `column` | `coreutils`, `bsdextrautils` |
| **GNU grep** | any with **PCRE** | `ssh-menu` uses `grep -P` with `\Q…\E` to match literal aliases | `grep` |
| **awk** | gawk or mawk | config parsing | `gawk` or `mawk` |
| **git** | any | your fleet repo is the source of truth | `git` |

The OpenSSH floor is 9.4 because that release added the `Tag` keyword, and an
older client rejects it as a bad configuration option. Delete the `Tag` lines
and 8.4 is enough (`SSH_ASKPASS_REQUIRE`, used by the saved-password helper);
without the saved-password helper too, 7.3 would do — `Include` and
`ProxyJump` both landed there.

### Required only for specific tools

| Tool | Needs | Package |
|---|---|---|
| `ssh-tmux` | **tmux ≥ 2.3** (`pane-border-status`, `synchronize-panes`) | `tmux` |
| `ssh-pass` | **python3**, **PyGObject**, **libsecret typelib**, and a running **Secret Service** | `python3`, `python3-gi`, `gir1.2-secret-1`, `gnome-keyring` |
| `ssh-tmux --window` | any terminal emulator | `gnome-terminal`, `konsole`, `xterm`, … |
| `ssh-menu -f` | `fzf` (optional; menus work without it) | `fzf` |

Verify the Secret Service before relying on `ssh-pass`:

```bash
python3 -c "import gi; gi.require_version('Secret','1'); from gi.repository import Secret; print('libsecret OK')"
gdbus call --session --dest org.freedesktop.secrets \
  --object-path /org/freedesktop/secrets \
  --method org.freedesktop.DBus.Properties.Get \
  org.freedesktop.Secret.Service Collections
```

Any Secret Service provider works — GNOME Keyring, KWallet, or KeePassXC with
its Secret Service integration enabled. `ssh-pass` is not GNOME-specific.

### One-line install of everything

```bash
sudo apt install -y openssh-client git tmux python3 python3-gi gir1.2-secret-1 \
                    gnome-keyring coreutils bsdextrautils gawk fzf
```

### Portability notes

- **macOS / BSD**: `ssh-menu` needs GNU `grep -P`, `sort -V` and `stat -c`.
  Install `coreutils` and `grep` from Homebrew and put them ahead on `PATH`, or
  the tree and menu will misbehave. The config files themselves are portable.
- **WSL**: keep `~/.ssh` on the Linux filesystem. Under `/mnt/c` the `chmod`
  will not stick without the `metadata` mount option, and ssh refuses keys and
  config files whose permissions are too open.
- `ssh-pass` is the only Python component. Everything else is shell.

### Verified on

Developed and tested against OpenSSH 10.2p1, tmux 3.6, bash 5.3, Python 3.14
and git 2.53 on Ubuntu. CI runs the test suite on the current Ubuntu LTS. The
minimums in the table above are the real feature floors, not the versions used
here.

---

## 2. Get it

The repository you clone will become the source of truth for **your** fleet,
and your fleet is private. Either fork it into a **private** repository, or
clone it and point `origin` at a private remote of your own:

```bash
git clone https://github.com/mbehnasr/ssh-fleet.git ~/ssh-fleet
cd ~/ssh-fleet
git remote rename origin upstream                 # keep upstream for updates
git remote add origin git@your-forge:you/ssh-fleet-private.git   # PRIVATE
```

Pull framework updates later with `git pull upstream main`.

---

## 3. Make it yours

Set your account name once, globally — the `User` line in `Host *`:

```bash
sed -i 's/^    #User your-account$/    User YOURNAME/' config
```

Then create your environments, either from an example or from scratch:

```bash
cp examples/config.d/staging.conf config.d/        # then edit the addresses
scripts/ssh-manage add-env staging                 # or start empty: creates config.d/staging.conf, offers a key
scripts/ssh-manage add-host staging k8s master1 198.51.100.31 --hostname stg-k8s-cp-01
```

`ssh-manage` works on the installed `~/.ssh/config.d`, so run step 4 first if
you start with it.

Generate one key per key-based environment:

```bash
ssh-keygen -t ed25519 -a 100 -f ~/.ssh/keys/<env>_ed25519 \
           -C "$(whoami)@$(hostname -s) <env> $(date +%Y-%m)"
chmod 600 ~/.ssh/keys/*; chmod 644 ~/.ssh/keys/*.pub
scripts/deploy-key.sh <env> --dry-run   # see the targets first
scripts/deploy-key.sh <env>             # asks before writing to any server
```

**Never copy a private key between people.** Each person generates their own and
has its public half added to `authorized_keys`.

---

## 4. Install

```bash
scripts/install.sh                 # symlink into ~/.ssh, create dirs, fix modes
```

An existing `~/.ssh/config` or `~/.ssh/config.d` is moved into
`~/.ssh/backup-<timestamp>/`, never deleted. `install.sh` also accepts `--copy`
for a machine that should not track the repo.

**Do not skip it.** Git records only the executable bit, so a fresh clone
produces mode-644 config files and **ssh refuses to read them**. `install.sh`
re-asserts `600` on every run. This is the usual reason a cloned SSH config
"suddenly stops working".

Put the tools on your `PATH`:

```bash
mkdir -p ~/.local/bin
for t in ssh-menu ssh-find ssh-manage ssh-hosts ssh-tmux ssh-pass ssh-askpass; do
    ln -sfn "$PWD/scripts/$t" ~/.local/bin/$t
done
```

The scripts find their shared parsers in `scripts/lib/` by resolving their own
symlink, so link them as above rather than copying individual files elsewhere.

Optional, to enable saved passwords (`~/.zshrc` or `~/.bashrc`):

```bash
export SSH_ASKPASS="$HOME/.local/bin/ssh-askpass"
export SSH_ASKPASS_REQUIRE=force
```

---

## 5. Verify

```bash
scripts/check.sh          # permissions, key passphrases, every alias resolves
scripts/ssh-hosts         # table of every alias and how it resolves
ssh-menu --tree           # the fleet as a tree
ssh -G <some-alias>       # the effective config for one host, no connection
```

`check.sh` should end with `0 error(s)`. It opens no network connections, so it
is safe to run anywhere, any time.

---

## 6. Daily use

```bash
ssh-menu                              # browse and connect (↑↓ or type a number)
ssh-menu -s stg-k8s-cp-01             # search by hostname, IP, note... (or press /)
ssh-find -c 198.51.100.31             # connect straight to whatever that matches
ssh <alias>                           # direct; zsh tab-completes aliases
ssh-menu --tree                       # whole fleet at a glance
ssh-tmux --group staging k8s          # a pane per host, input synchronised
ssh-manage add-host <env> <purpose> <server> <ip>
ssh-pass set --env <env>              # remember a password for an environment
```

Full reference, and the reasoning behind every setting, is in
[README.md](README.md).

---

## 7. Security expectations for a new user

- `~/.ssh` is `700`; config files and private keys are `600`; public keys `644`.
  `check.sh` enforces this.
- Every private key has a passphrase, and the passphrase lives in a password
  manager — never in the repository or a notes file. A key without one turns a
  stolen laptop into unrestricted fleet access.
- Keys are per environment, so a compromise in one cannot be replayed in
  another.
- `ForwardAgent` is off everywhere. Use `ProxyJump`, which keeps every private
  key on your workstation.
- Host keys are verified per environment (`~/.ssh/known_hosts.d/<env>`), because
  isolated environments reuse RFC 1918 addresses and a shared file would produce
  constant false alarms.
- No password is ever stored in the repository. `ssh-pass` puts them in the OS
  keyring instead.
- Your fleet repository is **private**. It is a map of your network.
