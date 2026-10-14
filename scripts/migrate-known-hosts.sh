#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Move existing host keys out of the single ~/.ssh/known_hosts into the
# per-environment files this config expects, so switching to per-environment
# known_hosts does not re-prompt you to trust hosts you already verified.
#
#   scripts/migrate-known-hosts.sh            show what would move (dry run)
#   scripts/migrate-known-hosts.sh --apply    write the per-environment files
#
# Nothing is deleted from the original known_hosts; entries are copied.
# Works with hashed entries (ssh-keygen -F searches hashes correctly).
# -----------------------------------------------------------------------------
set -euo pipefail
SSH_DIR="${SSH_DIR:-$HOME/.ssh}"
SRC="$SSH_DIR/known_hosts"
APPLY=0; [ "${1:-}" = "--apply" ] && APPLY=1

[ -f "$SRC" ] || { echo "no $SRC, nothing to migrate"; exit 0; }
mkdir -p "$SSH_DIR/known_hosts.d"; chmod 700 "$SSH_DIR/known_hosts.d"

grep -h '^Host ' "$SSH_DIR"/config.d/*.conf 2>/dev/null |
  sed 's/^Host //' | tr ' ' '\n' | grep -v '[*?]' | grep -v '^$' | sort -u |
while read -r a; do
    env="${a%%_*}"
    host=$(ssh -n -F "$SSH_DIR/config" -G "$a" 2>/dev/null | awk '$1=="hostname" {print $2; exit}')
    [ -z "$host" ] || [ "$host" = "$a" ] && continue
    entries=$(ssh-keygen -F "$host" -f "$SRC" 2>/dev/null | grep -v '^#' || true)
    [ -z "$entries" ] && continue
    dst="$SSH_DIR/known_hosts.d/$env"
    if [ "$APPLY" -eq 1 ]; then
        touch "$dst"; chmod 600 "$dst"
        while IFS= read -r line; do
            grep -qxF "$line" "$dst" 2>/dev/null || printf '%s\n' "$line" >> "$dst"
        done <<<"$entries"
        echo "moved  $host  ($a)  ->  known_hosts.d/$env"
    else
        echo "would move  $host  ($a)  ->  known_hosts.d/$env"
    fi
done

[ "$APPLY" -eq 1 ] || echo $'\nDry run. Re-run with --apply to write the files.'
