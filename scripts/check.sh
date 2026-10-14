#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Validate the installed SSH configuration. Safe: opens no connections.
#
#   scripts/check.sh            check everything
#   scripts/check.sh staging    check one environment
#
# Exit status: 0 clean, 1 errors found.
# -----------------------------------------------------------------------------
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SSH_DIR="${SSH_DIR:-$HOME/.ssh}"
FILTER="${1:-}"
errors=0; warns=0

err()  { printf '  \033[31mERROR\033[0m  %s\n' "$*"; errors=$((errors+1)); }
warn() { printf '  \033[33mWARN \033[0m  %s\n' "$*"; warns=$((warns+1)); }
ok()   { printf '  \033[32mok   \033[0m  %s\n' "$*"; }

# --- 1. permissions ----------------------------------------------------------
echo "== permissions =="
check_mode() {  # path expected-mode label
    local p="$1" want="$2" got
    [ -e "$p" ] || { warn "$p missing"; return; }
    got=$(stat -Lc '%a' "$p")
    if [ "$got" = "$want" ]; then ok "$p is $got"
    else err "$p is $got, expected $want   ->  chmod $want $p"; fi
}
check_mode "$SSH_DIR"                700
check_mode "$SSH_DIR/config"         600
check_mode "$SSH_DIR/config.d"       700
check_mode "$SSH_DIR/cm"             700
check_mode "$SSH_DIR/keys"           700
check_mode "$SSH_DIR/known_hosts.d"  700
for f in "$SSH_DIR"/config.d/*.conf; do [ -e "$f" ] && check_mode "$f" 600; done
for k in "$SSH_DIR"/keys/*; do
    [ -e "$k" ] || continue
    case "$k" in *.pub) check_mode "$k" 644 ;; *) check_mode "$k" 600 ;; esac
done

# --- 2. private keys: passphrase protected? ----------------------------------
echo; echo "== private keys =="
shopt -s nullglob
for k in "$SSH_DIR"/keys/*; do
    case "$k" in *.pub) continue ;; esac
    if ssh-keygen -y -P '' -f "$k" >/dev/null 2>&1; then
        warn "$(basename "$k") has NO passphrase (a stolen laptop is a stolen fleet)"
    else
        ok "$(basename "$k") is passphrase-protected"
    fi
done
[ -e "$SSH_DIR/keys" ] && [ -z "$(ls -A "$SSH_DIR/keys" 2>/dev/null)" ] && warn "no keys in $SSH_DIR/keys yet -- see README, 'Key generation'"

# --- 3. every alias resolves sanely ------------------------------------------
echo; echo "== host aliases =="
mapfile -t aliases < <(
    grep -h '^Host ' "$SSH_DIR"/config.d/*.conf 2>/dev/null |
    sed 's/^Host //' | tr ' ' '\n' |
    grep -v '[*?]' | grep -v '^$' | sort
)
dupes=$(printf '%s\n' "${aliases[@]}" | uniq -d)
[ -n "$dupes" ] && err "alias defined more than once: $(echo $dupes)"

declare -A seen_ip
declare -A missing_key
for a in $(printf '%s\n' "${aliases[@]}" | uniq); do
    [ -n "$FILTER" ] && case "$a" in "$FILTER"*) ;; *) continue ;; esac
    cfg=$(ssh -F "$SSH_DIR/config" -G "$a" 2>/dev/null) || { err "$a: ssh -G failed (syntax error?)"; continue; }
    get() { awk -v k="$1" '$1==k {print $2; exit}' <<<"$cfg"; }
    host=$(get hostname); user=$(get user); idf=$(get identityfile)
    pka=$(get pubkeyauthentication)

    # An internal alias (naming convention uses underscores, which are invalid
    # in DNS names) must define HostName. A real hostname like github.com
    # legitimately resolves to itself.
    case "$a" in
        *_*) [ "$host" = "$a" ] && { err "$a: no HostName -- ssh would resolve the alias in DNS"; continue; } ;;
    esac
    [ -z "$user" ] && err "$a: no User resolved"

    # Same address AND same login is a copy-paste duplicate. Same address with a
    # different login (a shell alias next to a git@ alias) is deliberate.
    if [ "${seen_ip[$host $user]:-}" != "" ]; then
        warn "$a and ${seen_ip[$host $user]} share HostName $host and User $user"
    else
        seen_ip[$host $user]="$a"
    fi

    if [ "$pka" = "yes" ] || [ "$pka" = "true" ]; then
        idf_expanded="${idf/#\~/$HOME}"
        # Report a missing key once, not once per host that references it.
        if [ -n "$idf" ] && [ ! -e "$idf_expanded" ]; then missing_key[$idf]=1; fi
    fi
done
for k in "${!missing_key[@]}"; do warn "IdentityFile $k does not exist yet (referenced by one or more hosts)"; done
ok "$(printf '%s\n' "${aliases[@]}" | uniq | wc -l) aliases defined"

# --- 3b. host metadata (# hostname: / # status: comments) --------------------
echo; echo "== host metadata =="
IDX_AWK="$REPO/scripts/lib/fleet-index.awk"
if [ -r "$IDX_AWK" ]; then
    idx=$(awk -f "$IDX_AWK" "$SSH_DIR"/config.d/*.conf 2>/dev/null)
    # One real hostname on two DIFFERENT addresses is nearly always a typo, or
    # an entry left behind when a node was rebuilt on a new IP. Two aliases for
    # the same address (git@ vs shell) are fine and not reported.
    while IFS= read -r line; do
        [ -n "$line" ] && warn "hostname $line"
    done < <(awk -F'\t' '
        $6 != "-" { k = $6 SUBSEP $5
                    if (!(k in seen)) { seen[k] = 1; ips[$6] = ips[$6] " " $5; n[$6]++ } }
        END       { for (h in n) if (n[h] > 1) print h " is on different addresses:" ips[h] }' <<<"$idx")
    ok "$(awk -F'\t' '$6 != "-"' <<<"$idx" | wc -l) of $(wc -l <<<"$idx") hosts carry a real hostname"
    nst=$(awk -F'\t' '$7 != "-"' <<<"$idx" | wc -l)
    [ "$nst" -gt 0 ] && ok "$nst hosts carry a status -- list them: grep -rn '# status:' $SSH_DIR/config.d"
else
    warn "missing $IDX_AWK -- search and hostname columns will not work"
fi

# --- 4. per-environment key + known_hosts wiring ------------------------------
echo; echo "== environments =="
for f in "$SSH_DIR"/config.d/*.conf; do
    [ -e "$f" ] || continue
    env=$(basename "$f" .conf); [ "$env" = "00-local" ] && continue
    # Only files that define <name>_* aliases are environments; others
    # (e.g. forges.conf) are legitimate non-environment config.
    first=$(printf '%s\n' "${aliases[@]}" | grep "^${env}_" | head -1)
    [ -z "$first" ] && { ok "$env.conf: not an environment (no ${env}_* aliases), skipped"; continue; }
    cfg=$(ssh -F "$SSH_DIR/config" -G "$first" 2>/dev/null)
    khf=$(awk '$1=="userknownhostsfile" {print $2; exit}' <<<"$cfg")
    idf=$(awk '$1=="identityfile" {print $2; exit}' <<<"$cfg")
    io=$(awk  '$1=="identitiesonly" {print $2; exit}' <<<"$cfg")
    case "$khf" in *"$env"*) ok "$env: own known_hosts ($khf)" ;;
                   *) warn "$env: shares known_hosts ($khf) -- IP reuse across environments will cause false host-key alarms" ;; esac
    # An environment may deliberately use password auth (no key deployed).
    # That is a choice, not a misconfiguration, so do not demand a key -- but do
    # insist that public-key auth is actually off, otherwise ssh still offers
    # the default identities and can hit MaxAuthTries before prompting.
    pka=$(awk '$1=="pubkeyauthentication" {print $2; exit}' <<<"$cfg")
    if [ "$pka" = "no" ] || [ "$pka" = "false" ]; then
        pa=$(awk '$1=="preferredauthentications" {print $2; exit}' <<<"$cfg")
        ok "$env: password auth by design (pubkey off, prefers $pa)"
        case "$pa" in *publickey*) warn "$env: PreferredAuthentications still lists publickey" ;; esac
    else
        case "$idf" in *"$env"*) ok "$env: own key ($idf)" ;;
                       *) warn "$env: key is $idf -- not environment-scoped" ;; esac
        [ "$io" = "yes" ] || err "$env: IdentitiesOnly is $io, expected yes"
    fi
done

echo
printf '== %d error(s), %d warning(s) ==\n' "$errors" "$warns"
[ "$errors" -eq 0 ]
