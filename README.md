# ssh-fleet

[![CI](https://github.com/mbehnasr/ssh-fleet/actions/workflows/ci.yml/badge.svg)](https://github.com/mbehnasr/ssh-fleet/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A multi-environment OpenSSH client configuration and a small set of terminal
tools for operating a fleet of hundreds of servers, built entirely on plain
`~/.ssh/config` and designed so that scaling up never means weakening a
security default.

- **One file per environment**, pulled in with `Include`, ordered so that
  OpenSSH's first-match-wins rule works *for* you instead of against you.
- **Per-environment keys and host-key databases**, so a compromise or an IP
  reused in one environment never leaks into another.
- **Bastions and network zones** expressed once per environment with
  `ProxyJump` — no agent forwarding, anywhere.
- **Tools that read the config instead of a second inventory:** an interactive
  picker with search (`ssh-menu`), a scriptable finder (`ssh-find`), safe
  add/remove with automatic rollback (`ssh-manage`), synchronised tmux panes
  (`ssh-tmux`), saved passwords in the OS keyring (`ssh-pass`), key
  bootstrapping (`deploy-key.sh`) and a validator that opens no connections
  (`check.sh`).
- **No cloud service, no daemon, no Internet.** It works fully air-gapped.

Connect with a meaningful alias, never an address:

```bash
ssh staging_ceph_node3      # -> you@198.51.100.53 via staging_bastion, staging key, staging host-key db
```

> **New here?** [INSTALL.md](INSTALL.md) covers dependencies and first-time
> setup. This file is the reference: every setting and the reasoning behind it.
> The [`examples/config.d/`](examples/config.d) environments use RFC 5737
> documentation addresses — copy them as a starting point.

## Quick start

```bash
git clone https://github.com/mbehnasr/ssh-fleet.git ~/ssh-fleet && cd ~/ssh-fleet
cp examples/config.d/staging.conf config.d/   # or: scripts/ssh-manage add-env <name>
scripts/install.sh                      # symlink into ~/.ssh, fix permissions
scripts/migrate-known-hosts.sh --apply  # keep host keys you already trust
scripts/check.sh                        # validate everything (opens no connections)
scripts/ssh-hosts                       # show every alias and how it resolves
```

`install.sh` moves an existing `~/.ssh/config` into a timestamped backup
directory first; nothing is deleted.

---

## 1. The one rule that drives the whole design

OpenSSH resolves options **first-obtained-wins**. The first time a keyword is
seen for a target, its value is locked in; later blocks can add new keywords but
can never override one already set. This is the opposite of most config systems
and everything here follows from it.

So the read order is deliberately **most specific → least specific**:

| Order | Source | Holds |
|---|---|---|
| 1 | `config.d/00-local.conf` | untracked personal overrides (wins over everything) |
| 2 | `config.d/<env>.conf` — individual `Host` blocks | only what is unique to one host |
| 3 | `config.d/<env>.conf` — group blocks (`Host staging_ceph_*`) | role/zone settings, e.g. `ProxyJump` |
| 4 | `config.d/<env>.conf` — environment block (`Host staging_*`) | key, host-key db, env policy |
| 5 | `~/.ssh/config` — `Host *` | workstation-wide defaults |
| 6 | `/etc/ssh/ssh_config` | distro defaults (lowest priority) |

Two practical consequences:

- **A single host overrides anything with one extra line** in its own block,
  because its block is read first. That is how `staging_sre_gitlab_git` gets
  `User git` while every other host inherits the fleet-wide `User`.
- **`Host *` must be last.** If you put the `Include` *after* the `Host *` block,
  every global default would win permanently and the environment files would
  become decorative. This is the single most common way this pattern is broken.

Verify the outcome, never assume it: `ssh -G <alias>` prints the effective config.

---

## 2. Directory structure

```
ssh-fleet/                              # git repo — the source of truth
├── config                              # -> symlinked to ~/.ssh/config
├── config.d/                           # -> symlinked to ~/.ssh/config.d
│   ├── 00-local.conf                   # untracked overrides (gitignored)
│   ├── 00-local.conf.example
│   ├── forges.conf                     # github.com / code forges (not an environment)
│   └── <env>.conf                      # one file per environment — yours
├── examples/config.d/                  # example environments (RFC 5737 addresses)
│   ├── staging.conf                    # key auth, two zones behind a bastion
│   ├── lab.conf                        # password auth, direct, host metadata
│   └── production.conf                 # strictest settings, two-hop bastion chain
├── scripts/
│   ├── install.sh                      # install + permissions
│   ├── check.sh                        # validate config, permissions, keys
│   ├── ssh-hosts                       # list aliases as ssh actually resolves them
│   ├── ssh-menu                        # interactive env -> purpose -> server picker
│   ├── ssh-find                        # find hosts by hostname, IP, note or status
│   ├── ssh-manage                      # add/remove hosts, purposes, environments
│   ├── ssh-tmux                        # one synchronised tmux pane per host
│   ├── ssh-pass                        # saved passwords in the OS keyring
│   ├── ssh-askpass                     # SSH_ASKPASS backend for ssh-pass
│   ├── deploy-key.sh                   # bootstrap a key onto hosts over password auth
│   ├── migrate-known-hosts.sh          # split known_hosts per environment
│   └── lib/                            # fleet-index.awk, fleet-search.awk (shared parsers)
├── tests/                              # smoke tests and the private-data guard
└── .gitignore                          # blocks every key pattern

~/.ssh/
├── config          -> repo/config
├── config.d/       -> repo/config.d
├── keys/                               # private keys — NEVER in the repo
│   ├── staging_ed25519(.pub)
│   └── production_ed25519(.pub)
├── known_hosts.d/                      # one host-key database per environment
│   ├── staging
│   └── …
└── cm/                                 # multiplexing control sockets
```

Keys and host-key databases live **outside** the repo on purpose: keys must never
be committed anywhere, and `known_hosts` is machine state, not configuration.

> **Keep your fleet private.** This repository ships only the framework and
> invented example hosts. The moment your own `config.d/<env>.conf` files hold
> real addresses, host names, roles and account names, that copy is a map of
> your network: push it **only to a private remote**. Git history is permanent
> — publishing a repository later exposes every past commit, and forks and
> code-search indexes keep it. `tests/check-no-private-data.sh` fails on any
> non-documentation IPv4 address and is a useful pre-push check for a fork
> you intend to share.

---

## 3. Naming convention

```
<environment>_<purpose>_<server>
```

| Part | Examples |
|---|---|
| environment | `staging`, `lab`, `production` |
| purpose | `k8s`, `ceph`, `sre`, `net`, `db` |
| server | `node3`, `master1`, `worker7`, `bastion` |

Why no IP in the alias:

- An address change becomes a one-line `HostName` edit instead of renaming an
  alias that is referenced in Ansible inventories, `scp` commands, scripts,
  runbooks and muscle memory.
- The alias is the stable identity. `ssh staging_ceph_node3` should keep working
  after the host is rebuilt on a new address.
- The prefix structure is what makes pattern blocks possible
  (`Host staging_k8s_worker*`). An IP suffix would defeat that.

Environment aliases are **prefix-disjoint**, so a new environment file cannot
collide with an existing one and the `Include` order never matters.

Tab completion works out of the box in zsh: `ssh staging_k8s_<TAB>`.

---

## 4. Day-2 operations

**Add a server** — two lines in the right section:

```
Host staging_ceph_node4
    HostName 198.51.100.54
```

It inherits the user, key, host-key database, timeouts, multiplexing and any
`ProxyJump` from the group and environment blocks below it. Then:

```bash
scripts/check.sh staging
ssh-copy-id -i ~/.ssh/keys/staging_ed25519.pub staging_ceph_node4
```

**Add an environment** — `ssh-manage add-env <name>` (§4c), or copy an example:

```bash
cp examples/config.d/staging.conf config.d/newenv.conf
sed -i 's/staging/newenv/g' config.d/newenv.conf     # aliases, key, known_hosts, Tag
ssh-keygen -t ed25519 -a 100 -f ~/.ssh/keys/newenv_ed25519 -C "$(whoami)@$(hostname -s) newenv $(date +%Y-%m)"
scripts/check.sh newenv
```

No change to `~/.ssh/config` is ever required — the `Include` glob picks the file
up automatically.

**Move a host between network zones** — move its alias between the two
`ProxyJump` pattern blocks. Topology lives in exactly one place per environment.

---

## 4b. Picking a host interactively

`scripts/ssh-menu` walks the three levels the naming convention encodes —
**environment → purpose → server** — and connects to what you pick.

```bash
ssh-menu                  # browse
ssh-menu --tree           # print the whole fleet and exit
ssh-menu staging k8s      # skip straight to a purpose group
ssh-menu --env staging    # set the sticky environment
ssh-menu --env-clear      # forget it
ssh-menu -s [text]        # search (or press / on any screen)
ssh-menu -f               # fuzzy search (needs fzf)
```

### Navigation

Move with **↑ ↓** (or `j`/`k`) and press **Enter**, or type an item number and
press Enter — both work. Numbers stay useful in long lists; arrows are faster in
short ones.

```
  staging › purpose

   ── recent ──
  > 1)   staging_k8s_master1        198.51.100.31    stg-k8s-cp-01
    2)   staging_ceph_node3         198.51.100.53    stg-ceph-03
   ── staging purposes ──
    3)  -              1 hosts
    4)  ceph           3 hosts
    5)  k8s            7 hosts
    6)  mgmt           1 hosts
    7)  sre            2 hosts

   /) search   e) change env   a) add server   q) quit
   ↑↓ move · pgup/pgdn · enter select · type a number
```

On the server screen every row gets a checkbox: **space** marks (and steps
down), `*` marks or clears all, and **`t`** opens the marked hosts in a
synchronised tmux session — see 4d. With nothing marked, `t` uses the row under
the cursor.

Hotkeys are context-aware: `/` search, `a` add, `d` remove, `e` change
environment, `b` back, `q` quit. PgUp/PgDn page through long lists, which
scroll inside the terminal instead of overflowing it.

Server rows show the alias's short name, IP and **real hostname**. A yellow `!`
marks a host carrying a status — for example a node no longer in its cluster
(see 4e). `a` and `d` pre-fill the environment and purpose from wherever
you are in the tree.

### Search

Press **`/`** on any screen — or start with `ssh-menu -s`, or `ssh-menu /text` —
and type anything you remember about a host: alias, IP, real hostname, role, a
word from a note, or its status. Every keystroke re-filters the whole fleet, and
several words must all match.

```
  search › k8s worker█
  8 of 32 hosts

  > [ ]   lab_k8s_worker01           192.0.2.21       lab-wk-01
    [ ]   lab_k8s_worker02           192.0.2.22       lab-wk-02
```

| Key | Does |
|---|---|
| type | filter |
| ↑ ↓ · PgUp PgDn | move |
| Enter | connect |
| Tab | mark or unmark, then step down |
| Ctrl-T | open the marked hosts (or the highlighted one) in synchronised tmux |
| Ctrl-U | clear the query |
| Esc | back to where you were |

Results are ranked, so a complete IP or node name puts that host first: an exact
alias / IP / hostname beats a prefix (`198.51.100.3`, `stg-k8s`), which beats a
substring, which beats a match found only in notes or status (`osd`,
`not a node`).

The same search works from the command line, for scripts and pipes:

```bash
ssh-find stg-k8s-cp-01                # table: alias, IP, hostname, status
ssh-find -c stg-k8s-cp-01             # connect if unique, else pick interactively
ssh-find -1 192.0.2.21                # print the alias only if exactly one matches
ssh-tmux $(ssh-find -a staging master)   # every staging master, synchronised
```

`-a`, `-1` and `-c` act on what they return, so they only count a match on the
alias, IP or hostname. A note such as "VIP, listed with the workers" does not
make `ssh-find -a lab worker` include the VIP. Notes and status are used
only when nothing else matches — which is why `ssh-find -a "not a node"`
still works. The table, and the interactive search, show every match.

### Sticky environment

The environment is remembered in `~/.ssh/.ssh-menu/env`, so after the first run
the menu opens straight onto **purpose → server** and stops asking. Press `e`
(or run `--env-clear`) to switch; picking a new one saves it. Passing an
environment as an argument is a one-off and does not overwrite the saved
context.

### Recent hosts

The ten most recently used hosts head the first screen, newest first, so the
common case is a single keystroke. History lives in `~/.ssh/.ssh-menu/history`
(capped at 500 lines, mode 600). Repeats collapse to their latest use, and hosts
that no longer exist in the config are filtered out, so a removed server cannot
linger in the list.

It parses the config files rather than shelling out to `ssh -G` per host, so it
stays instant at hundreds of servers. Two-part aliases such as `staging_bastion`
are filed under `(direct)`, and real DNS names such as `github.com` are excluded
since they are not fleet hosts. With no tty (piped or scripted) it falls back to
a plain numbered prompt, so it stays automatable.


## 4c. Adding and removing hosts

`scripts/ssh-manage` edits `config.d` for you. It is also reachable from inside
`ssh-menu` with the `a` and `d` keys, which pre-fill the environment and purpose
from wherever you are in the tree.

```bash
ssh-manage add-host                                   # fully interactive
ssh-manage add-host staging ceph node4 198.51.100.54  # or fully scripted
ssh-manage add-host lab k8s worker05 192.0.2.25 --hostname lab-wk-05
ssh-manage rm-host  staging_ceph_node4
ssh-manage add-env  pilot                             # new environment + optional key
ssh-manage rm-env   pilot
ssh-manage list
```

What it guarantees, and why each one matters:

- **New blocks always land above the wildcard blocks.** A host written below
  `Host <env>_*` would be unable to override anything, because OpenSSH is
  first-match-wins. It also inserts within the matching purpose section rather
  than at the end of the file, so the grouping stays readable.
- **Every write is backed up, validated, and rolled back on failure.** After
  editing it runs `ssh -G` on the affected alias; if the config no longer parses,
  or the alias does not resolve to an address, the backup is restored
  automatically. A bad edit cannot leave you with a broken SSH config.
- **Removal takes the host block and nothing else.** A block is its `Host` line
  plus indented option lines plus at most one trailing blank; a comment at column
  0 belongs to the next section and survives. Adding then removing a host returns
  the file byte-for-byte to its original state.
- **A shared `Host a b` line loses only the named alias**, not the whole block.
- **Duplicate aliases are refused**, and a duplicate `HostName` warns and asks
  before proceeding.

Backups are written next to the file as `<env>.conf.bak-<timestamp>`. They do not
end in `.conf`, so the `Include` glob ignores them, and `.gitignore` keeps them
out of the repository. Commit real changes as usual:

```bash
git add -A && git commit -m "staging: add ceph node4"
```

## 4d. Running one command on many hosts

`scripts/ssh-tmux` opens **one tmux pane per host with input synchronised**, so
a command typed once runs on all of them.

```bash
ssh-tmux staging_k8s_master1 staging_k8s_master2 staging_k8s_master3
ssh-tmux --group staging k8s            # a whole purpose group
ssh-tmux --group lab                    # a whole environment
ssh-tmux --pattern 'staging_k8s_worker*'  # glob over aliases
ssh-menu  ->  space to mark, t to launch
```

Options: `--no-sync` start unsynchronised, `--window` open a new terminal
window, `--no-attach` build and leave detached, `--force` open even when the
panes would be too small.

Sync is a tmux **window** property, so all hosts share one window. Toggle it
live with `C-b :setw synchronize-panes`, and the status bar always shows
`SYNC ON` / `sync off` — the one thing you cannot infer from the screen, and the
one thing you must be certain of before typing `rm`.

Details that matter in practice:

- **Every pane is titled with its alias** (`pane-border-status top`), so you
  always know which host you are typing into.
- **`remain-on-exit` is `failed`**: a host that refuses the connection keeps its
  pane so the error stays readable, while hosts you exit normally close. Exit
  every host and the session ends by itself instead of lingering detached.
- **Aliases are resolved before tmux starts.** A typo would otherwise open a
  pane that dies instantly among a dozen others.
- **Pane size is checked, not the pane count.** Using tmux's tiled layout and
  your terminal's real size it refuses only when a pane would be smaller than
  6 rows by 40 columns, and says how large the terminal needs to be. Thirteen
  hosts open fine maximised and are refused on 80x24. `--force` overrides it.
- **It attaches from the real terminal device.** tmux refuses a terminal
  reached through `/dev/tty` ("open terminal failed: can't use /dev/tty"), so
  `ssh-tmux` resolves `/dev/pts/N` first — before building anything, so a
  failure can never leave a session running that nobody can see.
- Run from inside tmux it uses `switch-client` rather than nesting an attach.

## 4e. Host metadata: real hostnames and status

A host block can carry structured comments. ssh ignores comments completely, so
they change nothing about how a connection behaves — but `ssh-menu`, `ssh-find`,
`ssh-hosts` and `check.sh` all read them:

```
Host lab_k8s_worker04
    HostName 192.0.2.24
    # hostname: lab-wk-04
    # status: not a node of the live cluster (kubectl get nodes, 2026-10-01)
    # any other indented comment is a free-text note, and searchable
```

| Line | Used for |
|---|---|
| `# hostname: <name>` | the node-name column in menus, `ssh-find` and `ssh-hosts`; search |
| `# status: <text>` | a yellow `!` on that host in every list, with the text beside it; search; counted by `check.sh` |
| any other indented comment | search |

Only **indented** comments belong to a host. A comment at column 0 is a section
heading and ends the block — the same boundary `ssh-manage` uses when it inserts
and removes hosts, so headings are never mistaken for host notes.

Comments rather than a separate inventory file, deliberately: the SSH config
stays the single source of truth, with no second file to drift out of sync, and
a host's address and identity change together in one diff.

`ssh-manage add-host … --hostname <name>` writes the line (and asks for it when
run interactively). `check.sh` warns when one hostname appears on two different
addresses, which is nearly always a typo or an entry left behind by a rebuild.

### Reconciling against a live Kubernetes cluster

Bookmarks record what someone once typed; `kubectl` reports what exists. On a
control-plane node:

```bash
kubectl get nodes -o wide
```

Each NAME / INTERNAL-IP pair is authoritative for which cluster a node belongs
to. Correct any alias that disagrees. For aliases the cluster no longer lists,
add a `# status:` line rather than deleting them: a node drained out of
Kubernetes is often still a running VM you need to reach.

Remember what kubectl cannot see. External etcd, haproxy, keepalived VIPs, Ceph,
registries and client boxes are not Kubernetes nodes, so their absence from
`kubectl get nodes` proves nothing about them.

### Beyond Kubernetes nodes

kubectl only knows nodes. For everything else, ask the system that owns it.
Every command here is read-only.

**Cluster plumbing** — on a control-plane node of each cluster:

```bash
sudo grep -E -- '--etcd-servers|--advertise-address' /etc/kubernetes/manifests/kube-apiserver.yaml
kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}{"\n"}'
kubectl -n kube-system get pods -o wide | grep -Ei 'etcd|haproxy|keepalived|kube-vip'
```

- `--etcd-servers=https://127.0.0.1:2379` means **stacked** etcd: separate
  etcd hosts filed under that cluster do not belong to it. Real addresses there
  are the external etcd members — match them to aliases.
- The API server URL points either at a master (no load balancer at all) or at
  a VIP, which sits in front of the haproxy nodes.

**Ceph** — on an admin node (prefix `sudo cephadm shell --` if the `ceph` CLI is
not installed on the host):

```bash
sudo ceph orch host ls
```

HOST, ADDR and LABELS give the hostname, address and role of every Ceph host.

**Anything else** — ask the host its own name. `ssh -n` stops ssh from
swallowing the loop's input, and the address filter skips placeholder networks:

```bash
awk -F'\t' '$6 == "-" && $5 !~ /^(192\.0\.2|198\.51\.100|203\.0\.113)\./ {print $1}' \
    <(awk -f scripts/lib/fleet-index.awk ~/.ssh/config.d/*.conf) |
while read -r a; do
    printf '%-28s ' "$a"; ssh -n -o ConnectTimeout=5 "$a" 'hostname -s' 2>&1 | tail -1
done
```

Skip VIPs: a VIP answers with the name of whichever node holds it right now.

**Is a flagged host still alive?**

```bash
for a in $(scripts/ssh-find -a "not a node"); do
    ip=$(ssh -G "$a" | awk '$1=="hostname"{print $2}')
    if timeout 3 bash -c "echo >/dev/tcp/$ip/22" 2>/dev/null; then s=up; else s=down; fi
    printf '%-26s %-16s %s\n' "$a" "$ip" "$s"
done
```

Run it with any VPN or proxy tunnel **off** (or bypassing private ranges). A TUN
proxy accepts every TCP connection itself, so every host would look alive.

## 5. SSH keys

### Generate (one key per environment)

```bash
ssh-keygen -t ed25519 -a 100 -f ~/.ssh/keys/staging_ed25519    -C "$(whoami)@$(hostname -s) staging $(date +%Y-%m)"
ssh-keygen -t ed25519 -a 100 -f ~/.ssh/keys/production_ed25519 -C "$(whoami)@$(hostname -s) production $(date +%Y-%m)"
chmod 600 ~/.ssh/keys/*; chmod 644 ~/.ssh/keys/*.pub
```

- `ed25519` — small, fast, no parameter choices to get wrong. Use
  `-t rsa -b 4096` **only** for a device too old to accept Ed25519 (OpenSSH < 6.5).
- `-a 100` — KDF rounds protecting the passphrase on disk. It only matters if the
  key *has* a passphrase, which is the whole point.
- `-C` — the comment lands in `authorized_keys` on every server; date and purpose
  make later auditing and rotation possible.
- **Use a passphrase on every key.** Without one, a copied laptop disk is
  unlimited fleet access. `scripts/check.sh` flags passphrase-less keys. Keep
  passphrases in a password manager — never in this repository, a README, or a
  notes file next to it.

Optional, air-gap friendly: a hardware-backed key
(`ssh-keygen -t ed25519-sk`) makes the private key non-exportable. It needs a
FIDO2 token and OpenSSH ≥ 8.2 on **both** ends — check your servers first.

### Deploy

One host:

```bash
ssh-copy-id -i ~/.ssh/keys/staging_ed25519.pub staging_ceph_node1
```

`-i …pub` matters: without it `ssh-copy-id` may push every key it can find.

A whole environment, entering the password once:

```bash
scripts/deploy-key.sh staging --dry-run    # list targets, contact nothing
scripts/deploy-key.sh staging              # prompts, confirms, then deploys
```

The password is read with `read -rs` and reaches ssh through an `SSH_ASKPASS`
helper in a 0700 temp directory that is removed on exit — it is never written to
a file, never in `argv` (so never visible in `ps`), and never in shell history.
This is the safe version of what `sshpass -p` does badly.

The script prints every target with its resolved `user@host` and requires you to
type `yes` before it writes to a single server. It skips service accounts
(`git`, `root`, `nobody`) unless you name the alias explicitly — pushing an
admin key to a forge's `git@` account grants repository access, not shell
access, and is nearly always a mistake. Wildcard blocks such as `Host staging_*`
are configuration rather than hosts and are never passed to ssh.

After deployment it verifies with `PreferredAuthentications=publickey` and
`PasswordAuthentication=no`, so a pass proves the key really works rather than
the password silently succeeding behind it.

### One key per environment, or one key for everything?

**Per environment, as configured here.** The trade-off:

| | Single key | Key per environment |
|---|---|---|
| Blast radius if stolen | entire fleet | one environment |
| Rotation | touch every server at once | one environment at a time, low risk |
| Offboarding / audit | one line everywhere, no separation | per-environment `authorized_keys` review |
| Cost | — | one passphrase and one agent entry per environment |

Per-environment keys are what makes `production` genuinely separable from
`staging`: a staging box that gets rooted holds an `authorized_keys` entry that
is useless anywhere else. Per-*host* keys are the next step up and are usually
not worth the operational cost — that is the job of an SSH CA (§8).

Do **not** reuse your personal `~/.ssh/id_ed25519` (git, GitHub, personal boxes)
for infrastructure. Different threat models, different rotation schedules.

---

## 6. ssh-agent

The agent holds decrypted keys in memory so the passphrase is typed once, and
performs signatures on request — the private key itself never leaves it.

**On GNOME desktops** the default agent is often `gcr-ssh-agent`
(`SSH_AUTH_SOCK=/run/user/<uid>/gcr/ssh`), which stores key passphrases in the
login keyring: keys unlock silently after login. Convenient, but it means an
unlocked desktop session is standing fleet access, and it ignores lifetime
constraints.

For infrastructure work, the plain OpenSSH agent is the better fit — it honours
`-t` lifetimes and `-c` confirmation. Most systemd-based distributions ship it as
a user unit:

```bash
systemctl --user enable --now ssh-agent.socket
# then in ~/.zshrc, before anything that uses ssh:
export SSH_AUTH_SOCK="${XDG_RUNTIME_DIR}/ssh-agent.socket"
```

Daily use:

```bash
ssh-add -l                                   # what is loaded (fingerprints)
ssh-add -L                                   # loaded keys in authorized_keys format
ssh-add ~/.ssh/keys/staging_ed25519          # load one key
ssh-add -t 8h ~/.ssh/keys/production_ed25519 # load with a lifetime (auto-forgets)
ssh-add -d ~/.ssh/keys/production_ed25519    # unload one key
ssh-add -D                                   # unload everything (do this before you walk away)
```

**Loading multiple keys** is handled automatically: `AddKeysToAgent yes` in
`Host *` loads each key the first time it is used, so you never pre-load
anything. `production` overrides this with `AddKeysToAgent 4h`, so the
production key expires from the agent even if the workstation stays up.

`AddKeysToAgent confirm` (a prompt per signature) needs an `SSH_ASKPASS` helper,
which is often not installed by default — `sudo apt install ssh-askpass-gnome`
(or your desktop's equivalent) first, or it silently fails.

Because `IdentitiesOnly yes` is set fleet-wide, extra loaded keys are never
offered to servers that did not ask for them.

**Never use `ForwardAgent`.** While forwarded, anyone with root on that server
can use your agent to authenticate anywhere your keys are trusted. `ProxyJump`
(§9) solves the same problem with all signing kept on the workstation. If some
tool genuinely forces it, scope it to one host and load that key with `ssh-add -c`.

---

## 7. Servers that still use passwords

No password belongs in `~/.ssh/config`, in this repo, in a shell alias, or in a
script. The config file only records *how* to authenticate:

```
Host staging_k8s_worker7
    HostName 198.51.100.47
    PubkeyAuthentication no
    PreferredAuthentications keyboard-interactive,password
```

Those two lines exist for a practical reason: with keys enabled, ssh offers each
key first, and sshd's default `MaxAuthTries 6` can disconnect you with *"Too many
authentication failures"* before it ever prompts for the password.

**Recommendation, in order:**

1. **Migrate to keys.** One command per host, and the password problem is gone:
   `ssh-copy-id -i ~/.ssh/keys/staging_ed25519.pub staging_k8s_worker7`,
   then delete the two override lines. For a whole environment, use
   `scripts/deploy-key.sh <env>` (§5), which asks for the password once.
   Once every admin is on keys, ask for `PasswordAuthentication no` in `sshd_config`.
2. **Until then, store passwords in a real password manager** — or in the OS
   keyring with `ssh-pass` (§7b). Offline, air-gap friendly options: `pass`
   (GPG-backed, plain files, git-syncable), KeePassXC (single encrypted database
   file), or an internally hosted Vaultwarden. All work with no Internet access.
   `pass show infra/staging/worker7 -c` puts it on the clipboard for 45 s.
3. **Do not use `sshpass`.** `sshpass -p 'secret'` exposes the password to every
   user on the machine via `ps`, and to your shell history. If automation truly
   cannot be fixed, `sshpass -f <file>` with mode 600 is the least-bad variant —
   but treat it as a migration deadline, not a solution.

**Never** set `PubkeyAuthentication no` in `Host *` to "make passwords work" —
that disables key authentication for the entire fleet.

---

## 7a. Which environments use keys, which use passwords

The examples cover both shapes:

| Environment | Auth | Why |
|---|---|---|
| `staging` | key (`staging_ed25519`) | the normal case |
| `production` | key + 4h agent lifetime | strictest |
| `lab` | **password** | chosen: no keys in this environment |

A password environment sets, in its `Host <env>_*` block:

```
PubkeyAuthentication no
PreferredAuthentications keyboard-interactive,password
```

`PubkeyAuthentication no` matters more than it looks. Merely leaving
`IdentityFile` unset is not enough: ssh would still offer the built-in default
identities (`~/.ssh/id_rsa`, `~/.ssh/id_ed25519`, …) to every host in the
environment. That leaks which keys you hold to any host you touch, and it burns
through sshd's `MaxAuthTries` (default 6), so you get *"Too many authentication
failures"* and a closed connection before you are ever offered the password
prompt. Turning pubkey auth off for these environments avoids both.
`check.sh` recognises this as a deliberate choice rather than a missing key.

Store the environment's password once (see 7b), and it stops prompting:

```bash
ssh-pass set --env lab
```

## 7b. Saved passwords (the MobaXterm equivalent)

MobaXterm remembers a password and stops asking. The equivalent here is
`scripts/ssh-pass`, which keeps secrets in the **login keyring** via
libsecret — encrypted at rest, unlocked with your session, never in a file in
this repo and never in shell history.

Enable it by pointing ssh at the helper (add to `~/.zshrc` or `~/.bashrc`):

```bash
export SSH_ASKPASS="$HOME/.local/bin/ssh-askpass"
export SSH_ASKPASS_REQUIRE=force
```

Then use it:

```bash
ssh-pass set staging_sre_gitlab   # one host
ssh-pass set --env lab            # one password for a whole environment
ssh-pass set --default            # one password for the entire fleet
ssh-pass list                     # what is stored (never the secrets)
ssh-pass get lab_k8s_master01     # which entry would be used
ssh-pass rm  --default
```

You are never asked to type a password into a command line: `set` prompts with
echo off, and the first time an unsaved host asks, the helper prompts on your
terminal, passes the answer to ssh, and offers to remember it — the MobaXterm
behaviour.

Lookup runs most-specific-first, so one entry can cover a lot of hosts:

| Order | Entry | Covers |
|---|---|---|
| 1 | `user@host` | that one host |
| 2 | `--env <name>` | every host in that environment |
| 3 | `--default` | everything else |

Any Secret Service provider works — GNOME Keyring, KWallet, or KeePassXC with
its Secret Service integration enabled.

### What it deliberately does not do

**It never auto-answers a host-key prompt.** With `SSH_ASKPASS_REQUIRE=force`
*every* prompt routes through the helper, including "Are you sure you want to
continue connecting?". Answering that from a store would silently defeat the one
check that detects a machine-in-the-middle, so the helper relays it to you and
waits.

### Read this before saving a fleet-wide password

If one account password works on every server, `--default` puts fleet-wide
access behind nothing but your unlocked desktop session — the same exposure
MobaXterm has, no better and no worse.

Two things already reduce the prompting without storing anything:

- **`ControlPersist 10m`** means a reconnection to the same host within ten
  minutes reuses the existing authenticated connection and never prompts.
- **Key authentication does not prompt at all.** `ssh-add` once per login and
  every key-based host is silent for the rest of the session.

So the intended shape is: keys everywhere (`scripts/deploy-key.sh`), and
`ssh-pass` only for hosts where a key cannot be deployed — vendor appliances,
switches, a box you have not onboarded yet. Used that way it is a small,
bounded exception rather than a second credential system running in parallel.

## 8. Host key verification at scale

Each environment has its own database:

```
UserKnownHostsFile ~/.ssh/known_hosts.d/staging
```

Isolated environments reuse RFC 1918 space, so the same address legitimately
belongs to different machines in different environments. With one shared
`known_hosts`, that produces a permanent *"REMOTE HOST IDENTIFICATION HAS
CHANGED"* banner — and a team that has learned to ignore the one warning that
actually means something. Separate files make each environment's trust
independent, and let you ship a pre-verified file to a new team member.

`scripts/migrate-known-hosts.sh` copies entries you already trust out of the
old flat `known_hosts` (it handles hashed entries via `ssh-keygen -F`), so
adopting this does not re-prompt you for hosts you have already verified.

**Seeding new hosts without a first-contact prompt:**

```bash
ssh-keyscan -t ed25519 198.51.100.54 >> ~/.ssh/known_hosts.d/staging
```

`ssh-keyscan` is only trust-on-first-use with extra steps — it trusts whatever
answers. Verify the fingerprint against a source the network cannot forge (the
host's console, or your config-management inventory):

```bash
# on the server, out of band:
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

**The real answer for hundreds of hosts is an SSH CA** — fully offline, no cloud
service, no external dependency:

```bash
# once, on an offline machine:
ssh-keygen -t ed25519 -f ~/ca/staging_host_ca -C "staging host CA"

# sign each server's host key (validity forces re-signing, i.e. rotation):
ssh-keygen -s ~/ca/staging_host_ca -I node4.staging -h -n node4,198.51.100.54 \
           -V +52w /etc/ssh/ssh_host_ed25519_key.pub
# server sshd_config:  HostCertificate /etc/ssh/ssh_host_ed25519_key-cert.pub

# workstation: trust every host signed by that CA, in one line
echo "@cert-authority * $(cat ~/ca/staging_host_ca.pub)" >> ~/.ssh/known_hosts.d/staging
```

One line replaces hundreds of `known_hosts` entries, rebuilt hosts stop
triggering warnings, and the same mechanism can issue short-lived *user*
certificates (`ssh-keygen -s user_ca … -n <login>`) so access expires on its own
instead of living forever in `authorized_keys`.

---

## 9. Bastions, ProxyJump and network zones

```
workstation ──ssh──> staging_bastion ──tcp forward──> 198.51.100.53
             └────────── end-to-end encrypted session ──────────┘
```

```
Host lab_bastion
    HostName 192.0.2.5

Host lab_ceph_admin01
    HostName 192.0.2.31

Host lab_ceph_* lab_k8s_*
    ProxyJump lab_bastion
```

`ssh lab_ceph_admin01` now transparently routes through the bastion. `scp`,
`rsync`, `ansible`, `sftp` and port forwards all follow, because they all read
this same file.

Why `ProxyJump` and not the alternatives:

- **vs. logging into the bastion and running `ssh` from there** — your session is
  then terminated *on the bastion*, so the bastion sees the plaintext, and you
  need credentials on it. With `ProxyJump` the bastion only forwards TCP; the
  encrypted session is end-to-end between your workstation and the target.
- **vs. `ForwardAgent`** — no private key or agent socket is ever exposed on the
  jump host. All signing happens locally.
- **vs. hand-written `ProxyCommand netcat …`** — `ProxyJump` needs no `nc` on the
  bastion, handles chains, and reuses this config for the jump host itself.

**Multiple zones** — chain jump hosts left to right, deepest pattern first
(first match wins), as in [`examples/config.d/staging.conf`](examples/config.d/staging.conf):

```
Host staging_k8s_worker*
    ProxyJump staging_bastion,staging_mgmt_jump   # two hops: workload zone

Host staging_k8s_* staging_ceph_* staging_sre_*
    ProxyJump staging_bastion                     # one hop: mgmt zone
```

Ad-hoc, without editing anything: `ssh -J staging_bastion 198.51.100.53`.

Make sure the bastion's own alias never matches the pattern that assigns
`ProxyJump`, or it will try to jump through itself.

Multiplexing (§10) is what makes this fast: the bastion connection is
authenticated once and every host behind it reuses it.

---

## 10. Connection multiplexing

```
ControlMaster auto
ControlPath ~/.ssh/cm/%C
ControlPersist 10m
```

**Yes, it is worth it** — arguably the single biggest quality-of-life win here.
The first connection authenticates; every later `ssh`/`scp`/`rsync`/Ansible task
to the same host reuses that channel and starts in milliseconds with no
passphrase, no key exchange, no bastion round-trip. Ansible against a Ceph
cluster goes from painful to instant.

Security notes, honestly stated:

- The socket **is** an authenticated session. Anyone who can write to
  `~/.ssh/cm` can ride it. Hence mode 700, and never `/tmp`.
- `%C` (a hash of local host, remote host, port, user and jump host) keeps the
  path short — UNIX socket paths are capped near 104 bytes, and `%h/%p/%r` paths
  overflow that with long alias names.
- `ControlPersist` is a time bomb in the good sense: `production` shortens it to
  5 minutes so a forgotten terminal is not a standing channel into production.

```bash
ssh -O check staging_ceph_node3     # is a master running?
ssh -O exit  staging_ceph_node3     # close it now
ssh -o ControlMaster=no staging_ceph_node3   # bypass for one connection
```

If a master hangs, every new session to that host hangs with it — `ssh -O exit`
or delete the socket under `~/.ssh/cm`.

---

## 11. Security checklist

### Permissions

```bash
chmod 700 ~/.ssh ~/.ssh/keys ~/.ssh/cm ~/.ssh/known_hosts.d
chmod 700 <repo> <repo>/config.d
chmod 600 ~/.ssh/config ~/.ssh/config.d/*.conf
chmod 600 ~/.ssh/keys/*                  # private keys
chmod 644 ~/.ssh/keys/*.pub              # public keys
chmod 600 ~/.ssh/known_hosts.d/*
chmod 600 ~/.ssh/authorized_keys
```

`scripts/check.sh` verifies all of this. Why it matters:

- ssh **refuses** to use a config file or private key that is group/world
  writable (or readable, for keys) — a wrong mode is a hard failure, not a
  warning.
- git does not track modes beyond the exec bit, so a fresh `git clone` produces
  `644` config files. `install.sh` re-asserts `600` on every run — this is the
  usual reason a cloned SSH config "suddenly stops working".
- The repo directory *is* `~/.ssh/config.d` through the symlink, so it must not
  be group-writable either (the default umask 002 makes it 775).

### The rest

| Practice | Setting | Why |
|---|---|---|
| Passphrase on every private key | — | a stolen disk is otherwise full fleet access |
| Only offer named keys | `IdentitiesOnly yes` | stops key enumeration leaks and `MaxAuthTries` lockouts |
| Never forward the agent | `ForwardAgent no` | root on the remote host can use your keys; use `ProxyJump` |
| Never forward X11 | `ForwardX11 no` | a hostile X client can capture keystrokes |
| Fail on changed host keys | `StrictHostKeyChecking ask` / `yes` in prod | this is the MITM detector; `no` disables it entirely |
| Hash the host database | `HashKnownHosts yes` | a stolen file stops being a network map |
| Survive host-key rotation | `UpdateHostKeys yes` | lets servers rotate without lockouts |
| Skip unused auth | `GSSAPIAuthentication no` | Ubuntu enables it globally; pointless with no KDC |
| Scope legacy crypto | per-host `HostKeyAlgorithms +ssh-rsa` | never weaken `Host *` for one old appliance |
| Expire production access | `AddKeysToAgent 4h` | overnight the key is gone from the agent |
| Keep secrets out of history | see below | |

**`Host *` versus specific blocks.** `Host *` is for things that are safe
everywhere and must be defaulted *safely* — user, timeouts, and every "off"
switch. It is never the place for a fix to one broken host: `PubkeyAuthentication
no`, `StrictHostKeyChecking no`, `HostKeyAlgorithms +ssh-rsa` or
`UserKnownHostsFile /dev/null` in `Host *` silently downgrade the entire fleet,
and because of first-match-wins the damage is invisible in the per-host blocks.
Put the exception in the host's own block, where `ssh -G` and code review can
see it.

**Shell history hygiene.** History files are plaintext, world-readable to
anything running as you, and get synced into backups.

```bash
# zsh (~/.zshrc)
setopt HIST_IGNORE_SPACE          # any command starting with a space is not recorded
setopt HIST_NO_STORE              # do not record 'history' itself
```

Then prefix sensitive commands with a space. Better still, never put a secret in
`argv` at all: use `ssh-add` (prompts), `pass show … -c` (clipboard), or
`read -rs VAR` — and remember that `argv` is visible in `ps` to every local user
regardless of history settings. To scrub something already recorded:

```bash
grep -n 'sshpass\|password' ~/.zsh_history     # find it
# edit the file, then:  fc -R ~/.zsh_history
```

---

## 12. Debugging

### `ssh -G` — what the config actually resolves to (no connection made)

```bash
ssh -G staging_ceph_node3
ssh -G staging_ceph_node3 | grep -E '^(user|hostname|port|identityfile|identitiesonly|proxyjump|proxycommand|connecttimeout|serveralive|preferredauthentications|pubkeyauthentication|controlmaster|controlpath|userknownhostsfile|forwardagent) '
```

| Look for | Expected | If it is wrong |
|---|---|---|
| `user` | your fleet account | a `Host *` or earlier block set it first |
| `hostname` | the IP — **never the alias** | `HostName` missing; ssh would resolve the alias in DNS |
| `port` | `22` | check for a stray `Port` |
| `identityfile` | `~/.ssh/keys/<env>_ed25519` | environment block not matching the alias pattern |
| `identitiesonly` | `yes` | other keys will be offered too |
| `pubkeyauthentication` | `true` (OpenSSH 10 prints booleans as `true`/`false`) | a password override is active |
| `preferredauthentications` | `publickey,…` | password-first means the key is disabled |
| `proxyjump` | the bastion chain, or empty | pattern block ordering |
| `connecttimeout` | `10` | — |
| `userknownhostsfile` | `~/.ssh/known_hosts.d/<env>` | wrong environment file matched |

Compare two hosts to find what makes one different:

```bash
diff <(ssh -G staging_ceph_node1) <(ssh -G staging_k8s_worker1)
```

`scripts/ssh-hosts` runs `ssh -G` over every alias and prints the result as a
table — use it as the fleet-wide version of the same check.

### `ssh -vvv` — what actually happens on the wire

```bash
ssh -vvv staging_ceph_node3
ssh -vvv staging_ceph_node3 2>&1 | tee /tmp/ssh-debug.log
```

Lines worth finding:

| Line | Means |
|---|---|
| `debug1: Reading configuration data …` | which files were parsed, in which order |
| `debug1: Connecting to 198.51.100.53 [198.51.100.53] port 22` | the address it really used |
| `debug1: Executing proxy command` / `debug1: Setting up multiplex …` | jump host / socket reuse in play |
| `debug1: Server host key: ssh-ed25519 SHA256:…` | fingerprint to compare out of band |
| `debug1: Host '…' is known and matches the … host key` | host key verification passed |
| `debug1: Offering public key: … explicit` | *your* key was offered (`explicit` = from config, not the agent) |
| `debug1: Authentications that can continue: publickey,password` | what the **server** accepts |
| `debug1: Authentication succeeded (publickey)` | which method won |
| `Too many authentication failures` | too many keys offered — `IdentitiesOnly` / `PubkeyAuthentication no` |
| `debug1: No more authentication methods to try` | server rejected the key; look at its `/var/log/auth.log` |

Useful isolation tricks:

```bash
ssh -F /dev/null -vvv <user>@198.51.100.53        # ignore this config entirely: is it the config or the server?
ssh -o ControlMaster=no -vvv staging_ceph_node3   # bypass a stale multiplex socket
ssh -o BatchMode=yes staging_ceph_node3 true      # scriptable reachability test, never prompts
ssh -Q key                                         # key types this client supports
ssh-keygen -lf ~/.ssh/keys/staging_ed25519.pub     # fingerprint, to match against authorized_keys
```

### When it is not SSH at all: a proxy/VPN TUN swallowing internal routes

Symptom — `ssh` gets a TCP connection and then dies *before* the version
exchange, on every host in an environment:

```
debug1: Connection established.
kex_exchange_identification: Connection closed by remote host
```

That is not authentication, not host keys, and not this config: the session
never got as far as either. A split-tunnel proxy in TUN mode (Clash-family
clients, Tailscale, corporate VPN clients) will happily accept the TCP handshake
on a fake address and then drop it, because it cannot reach your internal
network. `ping` may still "succeed" against the same fake address, which makes
it look like the host is up.

Diagnose in three commands:

```bash
ip route get 198.51.100.53       # does it leave via a tun/proxy device?
ip rule show                     # a catch-all rule sending everything to a proxy table
timeout 5 bash -c 'exec 3<>/dev/tcp/198.51.100.53/22 && head -c 40 <&3'   # real sshd banner?
```

A real server answers with `SSH-2.0-OpenSSH_…`. Silence plus an open socket means
something in the middle is terminating the connection.

Fix it in the proxy, not in SSH: exclude internal ranges from the tunnel so they
route directly. In Clash-family configs that is a private-network DIRECT rule
placed above the catch-all:

```yaml
rules:
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve
  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
  # or, equivalently:  GEOIP,private,DIRECT,no-resolve
```

Never "work around" this by disabling host key checking or switching to password
auth — the transport is broken, and neither change can help.

Server side, when the client looks fine: `sudo journalctl -u ssh -f`
(permissions on the server's `~/.ssh` and `authorized_keys` are the usual cause —
they must be `700`/`600` and owned by the user).

---

## 13. Air-gapped operation

Nothing here needs the Internet or any external service:

- No cloud SSH broker, no SSM/IAP/Teleport dependency, no external secret store.
- Key generation, the optional SSH CA, `known_hosts` distribution and password
  storage (`pass`, KeePassXC, the OS keyring) are all local-only.
- `GSSAPIAuthentication no` and the explicit `ConnectTimeout` remove waits that
  come from unreachable directory services.
- The only optional Internet-adjacent items are called out as optional:
  hardware FIDO2 keys (offline once purchased) and Vaultwarden (self-hosted).

For a second workstation or a new team member: clone your (private) fleet repo,
run `scripts/install.sh`, generate *their own* keys (never copy private keys
between people), and hand over the `known_hosts.d/` files or the CA public key.

---

## 14. Design decisions

| Decision | Why |
|---|---|
| `Include` before `Host *` | OpenSSH is first-match-wins; the reverse makes environment files decorative |
| Aliases carry no IP | an address change is a one-line `HostName` edit, not a fleet-wide rename |
| One key per key-based environment | a compromise in one cannot be replayed in another |
| `known_hosts` per environment | isolated environments reuse RFC 1918 space; a shared file breeds false alarms |
| Password environments turn pubkey auth off | default keys would otherwise exhaust `MaxAuthTries` before the prompt |
| Host metadata in `# hostname:` / `# status:` comments | ssh ignores them, so the config stays the single source of truth |
| The owning system outranks bookmarks | kubectl for nodes, `ceph orch` for Ceph, the host itself for its name |
| Departed nodes are flagged, not deleted | a node drained from Kubernetes is often still a VM to reach |
| Passwords in the OS keyring, never the repo | encrypted at rest; the repo stays safe to clone |
| No `ForwardAgent`, anywhere | `ProxyJump` keeps every signature on the workstation |
| Tools ask before any server-side write | holding a credential is not authorisation to act on every host |

---

## 15. Command cheat sheet

```bash
# install / verify
scripts/install.sh                       # symlink into ~/.ssh + permissions
scripts/install.sh --copy                # copy instead of symlink
scripts/check.sh [env]                   # validate config, permissions, keys
scripts/ssh-hosts [env]                  # table of every alias and how it resolves
scripts/ssh-menu [env] [purpose]         # interactive picker; --tree for the full tree
scripts/ssh-menu -s [text]               # search everything (or press / in the menu)
scripts/ssh-find <text> [-a|-1|-c]       # search from scripts and pipes
scripts/deploy-key.sh <env> [--dry-run]  # bootstrap a key onto an environment
scripts/ssh-manage add-host|rm-host|add-env|rm-env   # edit config.d safely
scripts/ssh-tmux <alias>... | --group <env> [purpose]  # synchronised tmux panes
scripts/ssh-pass set|get|list|rm         # saved passwords in the login keyring
scripts/migrate-known-hosts.sh --apply   # split known_hosts per environment

# keys
ssh-keygen -t ed25519 -a 100 -f ~/.ssh/keys/<env>_ed25519 -C "$(whoami)@$(hostname -s) <env> $(date +%Y-%m)"
ssh-copy-id -i ~/.ssh/keys/<env>_ed25519.pub <alias>
ssh-keygen -lf ~/.ssh/keys/<env>_ed25519.pub
ssh-keygen -p -f ~/.ssh/keys/<env>_ed25519      # add/change a passphrase

# agent
ssh-add -l | -L | -D
ssh-add -t 8h ~/.ssh/keys/production_ed25519
export SSH_AUTH_SOCK="${XDG_RUNTIME_DIR}/ssh-agent.socket"   # use the OpenSSH agent

# permissions
chmod 700 ~/.ssh ~/.ssh/keys ~/.ssh/cm ~/.ssh/known_hosts.d
chmod 600 ~/.ssh/config ~/.ssh/config.d/*.conf ~/.ssh/keys/*
chmod 644 ~/.ssh/keys/*.pub

# host keys
ssh-keygen -F <ip> -f ~/.ssh/known_hosts.d/<env>     # look up (works on hashed entries)
ssh-keygen -R <ip> -f ~/.ssh/known_hosts.d/<env>     # remove after a legitimate rebuild
ssh-keyscan -t ed25519 <ip> >> ~/.ssh/known_hosts.d/<env>

# debug
ssh -G <alias>            # effective config, no connection
ssh -vvv <alias>          # full connection trace
ssh -J <bastion> <ip>     # ad-hoc jump
ssh -O check|exit <alias> # multiplex master control
ssh -F /dev/null -vvv <user>@<ip>   # rule out this config
```

---

## Contributing, security and license

- Bug reports, ideas and pull requests are welcome — see
  [CONTRIBUTING.md](CONTRIBUTING.md). Planned work is in [ROADMAP.md](ROADMAP.md).
- **Never paste real addresses, host names or credentials** into an issue or
  PR; reproduce with the documentation ranges used in `examples/`.
- Security problems: please report privately, as described in
  [SECURITY.md](SECURITY.md).
- Released under the [MIT License](LICENSE).
