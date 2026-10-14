#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Deploy an environment's public key to its hosts, bootstrapping over password
# authentication.
#
#   scripts/deploy-key.sh staging                  # every staging host
#   scripts/deploy-key.sh staging --dry-run        # list targets, touch nothing
#   scripts/deploy-key.sh staging staging_ceph_node1 staging_k8s_lb1
#
# The password is read once with `read -rs`: it is never written to a file,
# never appears in argv (so never in `ps`), and never enters shell history. It
# reaches ssh through an SSH_ASKPASS helper in a 0700 temp dir that is deleted
# on exit.
#
# Every run prints the exact host list and asks for confirmation before it
# writes to a single server.
# -----------------------------------------------------------------------------
set -uo pipefail

SSH_DIR="${SSH_DIR:-$HOME/.ssh}"
ENV="${1:-}"
[ -z "$ENV" ] && { sed -n '3,18p' "$0" | sed 's/^# \?//'; exit 2; }
shift

DRY=0
[ "${1:-}" = "--dry-run" ] && { DRY=1; shift; }

PUB="$SSH_DIR/keys/${ENV}_ed25519.pub"
[ -f "$PUB" ] || { echo "no public key at $PUB" >&2; exit 1; }

# --- target list -------------------------------------------------------------
EXPLICIT=0
if [ "$#" -gt 0 ]; then
    targets=("$@"); EXPLICIT=1
else
    # Concrete aliases only -- wildcard blocks such as "Host staging_*" are
    # configuration, not hosts, and must never be passed to ssh.
    mapfile -t targets < <(
        grep -h '^[[:space:]]*Host[[:space:]]' "$SSH_DIR/config.d/${ENV}.conf" 2>/dev/null |
        sed 's/^[[:space:]]*Host[[:space:]]*//' | tr ' ' '\n' |
        grep -v '[*?]' | grep -v '^$' | sort -u
    )
fi
[ "${#targets[@]}" -eq 0 ] && { echo "no hosts found for environment '$ENV'" >&2; exit 1; }

# Service accounts are never key-bootstrap targets: pushing an admin key to a
# forge's git@ account grants repository access, not shell access, and is
# almost always a mistake. Name such an alias explicitly to override.
if [ "$EXPLICIT" -eq 0 ]; then
    kept=(); skipped=()
    for t in "${targets[@]}"; do
        u=$(ssh -G "$t" 2>/dev/null | awk '$1=="user"{print $2; exit}')
        case "$u" in
            git|root|nobody) skipped+=("$t ($u)") ;;
            *) kept+=("$t") ;;
        esac
    done
    targets=("${kept[@]}")
    if [ "${#skipped[@]}" -gt 0 ]; then
        printf 'Skipping service accounts (name them explicitly to include):\n'
        printf '   %s\n' "${skipped[@]}"
        echo
    fi
fi

echo "Environment : $ENV"
echo "Public key  : $PUB"
echo "Fingerprint : $(ssh-keygen -lf "$PUB" | awk '{print $2}')"
echo "Targets     : ${#targets[@]}"
for t in "${targets[@]}"; do
    printf '   %-26s %s\n' "$t" "$(ssh -G "$t" 2>/dev/null | awk '$1=="user"{u=$2} $1=="hostname"{h=$2} END{print u"@"h}')"
done

if [ "$DRY" -eq 1 ]; then echo; echo "Dry run - nothing was contacted."; exit 0; fi

echo
printf 'This APPENDS the key to ~/.ssh/authorized_keys on each host above.\nType "yes" to proceed: '
read -r confirm
[ "$confirm" = "yes" ] || { echo "aborted."; exit 1; }

# --- password, held only in this process tree --------------------------------
printf 'Password (once, for all hosts): '
read -rs SSH_PW; echo
[ -z "$SSH_PW" ] && { echo "empty password, aborted." >&2; exit 1; }
export SSH_PW

TMPD=$(mktemp -d) || exit 1
chmod 700 "$TMPD"
trap 'rm -rf "$TMPD"; unset SSH_PW' EXIT INT TERM
cat > "$TMPD/askpass" <<'HELPER'
#!/bin/sh
printf '%s\n' "$SSH_PW"
HELPER
chmod 700 "$TMPD/askpass"
export SSH_ASKPASS="$TMPD/askpass" SSH_ASKPASS_REQUIRE=force DISPLAY="${DISPLAY:-:0}"

# --- deploy ------------------------------------------------------------------
ok=0; fail=0; failed=()
echo
for t in "${targets[@]}"; do
    if timeout 45 ssh-copy-id -i "$PUB" \
        -o PubkeyAuthentication=no \
        -o PreferredAuthentications=password,keyboard-interactive \
        -o StrictHostKeyChecking=yes \
        -o ConnectTimeout=10 -o NumberOfPasswordPrompts=1 \
        "$t" >/dev/null 2>&1
    then printf '  %-26s deployed\n' "$t"; ok=$((ok+1))
    else printf '  %-26s FAILED\n'   "$t"; fail=$((fail+1)); failed+=("$t"); fi
done
echo "  ---- deployed: $ok   failed: $fail ----"

if [ "$fail" -gt 0 ]; then
    echo
    echo "Diagnose a failure without changing anything:"
    echo "  ssh -v -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 ${failed[0]}"
    echo "Common causes: the account does not exist on that host, a different"
    echo "username is required, or sshd has PasswordAuthentication no."
fi

# --- verify ------------------------------------------------------------------
echo
if ssh-add -l 2>/dev/null | grep -q "${ENV}_ed25519"; then
    echo "Verifying key authentication (password disabled):"
    for t in "${targets[@]}"; do
        if timeout 20 ssh -o BatchMode=yes -o PreferredAuthentications=publickey \
             -o PasswordAuthentication=no -o ConnectTimeout=10 "$t" true 2>/dev/null
        then printf '  %-26s key auth OK\n' "$t"
        else printf '  %-26s key auth not working\n' "$t"; fi
    done
else
    echo "Load the key to verify key auth end to end:"
    echo "  ssh-add $SSH_DIR/keys/${ENV}_ed25519 && $0 $ENV --dry-run"
fi
