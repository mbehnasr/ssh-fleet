#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Install this repository into ~/.ssh with correct ownership and permissions.
#
#   scripts/install.sh            symlink ~/.ssh/config* -> repo (default)
#   scripts/install.sh --copy     copy instead (for machines without the repo)
#   SSH_DIR=/tmp/x scripts/install.sh --copy      install somewhere else (test)
#
# Existing files are moved into a timestamped backup directory, never deleted.
# -----------------------------------------------------------------------------
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SSH_DIR="${SSH_DIR:-$HOME/.ssh}"
MODE="link"

case "${1:-}" in
    --copy) MODE="copy" ;;
    --link|"") MODE="link" ;;
    *) echo "usage: $0 [--link|--copy]" >&2; exit 2 ;;
esac

say() { printf '  %s\n' "$*"; }

echo "==> Installing $REPO -> $SSH_DIR (mode: $MODE)"

# --- directories -------------------------------------------------------------
# 700 everywhere: ssh refuses group/world-writable config, and a readable
# ~/.ssh/cm would let another local user hijack a multiplexed session.
for d in "$SSH_DIR" "$SSH_DIR/keys" "$SSH_DIR/cm" "$SSH_DIR/known_hosts.d"; do
    mkdir -p "$d"
    chmod 700 "$d"
done
say "directories ready (700): keys/ cm/ known_hosts.d/"

# --- back up anything already there -----------------------------------------
BACKUP="$SSH_DIR/backup-$(date +%Y%m%d-%H%M%S)"
backed_up=0
for target in "$SSH_DIR/config" "$SSH_DIR/config.d"; do
    if [ -e "$target" ] || [ -L "$target" ]; then
        # Leave our own symlinks alone; they are simply refreshed below.
        if [ -L "$target" ] && [ "$(readlink -f "$target")" = "$(readlink -f "$REPO/$(basename "$target")")" ]; then
            continue
        fi
        mkdir -p "$BACKUP"; chmod 700 "$BACKUP"
        mv "$target" "$BACKUP/"
        backed_up=1
    fi
done
[ "$backed_up" -eq 1 ] && say "existing config moved to $BACKUP"

# --- untracked local override file -------------------------------------------
if [ ! -e "$REPO/config.d/00-local.conf" ]; then
    cp "$REPO/config.d/00-local.conf.example" "$REPO/config.d/00-local.conf"
    say "created config.d/00-local.conf (gitignored, all lines commented)"
fi

# --- permissions on the repo copies ------------------------------------------
# git does not track file modes beyond the exec bit, so a fresh clone comes out
# 644 and ssh will refuse it. Re-assert 600 on every install.
chmod 600 "$REPO/config" "$REPO/config.d/"*.conf
# The repo *is* ~/.ssh/config.d in link mode: a group-writable directory
# would let any member of the group swap a config file under ssh.
chmod 700 "$REPO" "$REPO/config.d"

# --- install -----------------------------------------------------------------
if [ "$MODE" = link ]; then
    ln -sfn "$REPO/config"   "$SSH_DIR/config"
    ln -sfn "$REPO/config.d" "$SSH_DIR/config.d"
    say "symlinked config and config.d/ (edit the repo, git tracks the change)"
else
    install -m 600 "$REPO/config" "$SSH_DIR/config"
    mkdir -p "$SSH_DIR/config.d"; chmod 700 "$SSH_DIR/config.d"
    install -m 600 "$REPO/config.d/"*.conf "$SSH_DIR/config.d/"
    say "copied config and config.d/*.conf"
fi

# --- verify ------------------------------------------------------------------
# NOTE: "Include ~/.ssh/config.d/*.conf" is an absolute path, so a copy-mode
# install into a non-default SSH_DIR can only be syntax-checked, not resolved.
# The probe is the first concrete fleet alias (<env>_...), if there is one yet.
probe=$(grep -h '^[[:space:]]*Host[[:space:]]' "$REPO"/config.d/*.conf 2>/dev/null |
        sed 's/^[[:space:]]*Host[[:space:]]*//' | tr ' ' '\n' |
        grep -v '[*?.]' | grep '_' | head -1 || true)
if [ "$SSH_DIR" = "$HOME/.ssh" ] && [ -n "$probe" ]; then
    resolved=$(ssh -G "$probe" 2>/dev/null | awk '$1=="hostname"{print $2}')
    if [ -n "$resolved" ] && [ "$resolved" != "$probe" ]; then
        say "verified: $probe -> $resolved"
    else
        echo "  !! $probe did not resolve to an address (got '$resolved')" >&2
        exit 1
    fi
else
    ssh -F "$SSH_DIR/config" -G "${probe:-install-probe-host}" >/dev/null || { echo "  !! config failed to parse" >&2; exit 1; }
    if [ -z "$probe" ]; then say "syntax OK (no hosts yet: copy one from examples/config.d or run ssh-manage add-env)"
    else say "syntax OK (non-default SSH_DIR: aliases resolve only from ~/.ssh)"; fi
fi

echo "==> Done. Next: scripts/check.sh"
