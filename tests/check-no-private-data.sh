#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Fail if the repository contains anything that looks like real infrastructure
# data or key material. Run it before every push of a repo you intend to share.
#
#   tests/check-no-private-data.sh            scan tracked files (or all, outside git)
#   tests/check-no-private-data.sh FILE...    scan the given files
#
# What it rejects:
#   - any IPv4 address outside the RFC 5737 documentation ranges
#     (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24), loopback, and the
#     network base addresses used in CIDR rules (10.0.0.0, 172.16.0.0, ...)
#   - private key blocks of any kind
#   - every term listed in .private-terms (one per line, case-insensitive).
#     That file is gitignored: list your internal domains, hostname prefixes,
#     account names and environment names there, and the guard catches them
#     without the list itself ever being published.
#
# Exit status: 0 clean, 1 something found.
# -----------------------------------------------------------------------------
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TERMS_FILE="$REPO/.private-terms"

# Explicit files are taken relative to the caller's directory; otherwise scan
# this repository.
if [ "$#" -gt 0 ]; then
    files=("$@")
else
    cd "$REPO" || exit 1
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        mapfile -t files < <(git ls-files --cached --others --exclude-standard)
    else
        mapfile -t files < <(find . -type f -not -path './.git/*' | sed 's|^\./||')
    fi
fi

# The terms list names exactly what must not be published; never scan it.
for i in "${!files[@]}"; do
    case "${files[$i]}" in .private-terms|./.private-terms|"$TERMS_FILE") unset 'files[i]' ;; esac
done
files=("${files[@]}")

found=0
report() { printf '  %s\n' "$*"; found=1; }

# --- IPv4 addresses ----------------------------------------------------------
allowed_ip() {
    case "$1" in
        192.0.2.*|198.51.100.*|203.0.113.*) return 0 ;;   # RFC 5737
        127.*|0.0.0.0) return 0 ;;                         # loopback / any
        10.0.0.0|172.16.0.0|192.168.0.0) return 0 ;;       # CIDR bases in docs
    esac
    return 1
}
# A dotted quad not glued to more digits or dots: a trailing full stop ends a
# sentence, a fifth number makes it a version string. Every match is reported.
while IFS=: read -r f n ip; do
    allowed_ip "$ip" || report "$f:$n: non-documentation IPv4 address $ip"
done < <(grep -HnoP '(?<![0-9])(?<![0-9]\.)(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9])(?!\.[0-9])' -- "${files[@]}" 2>/dev/null)

# --- key material ------------------------------------------------------------
while IFS= read -r hit; do
    report "$hit: private key block"
done < <(grep -HnE -- '-----BEGIN ([A-Z]+ )?PRIVATE KEY-----' -- "${files[@]}" 2>/dev/null |
         grep -v '^tests/check-no-private-data.sh:' | cut -d: -f1,2)

# --- site-specific terms -----------------------------------------------------
if [ -f "$TERMS_FILE" ]; then
    while IFS= read -r term; do
        term="${term%%#*}"; term="${term#"${term%%[![:space:]]*}"}"; term="${term%"${term##*[![:space:]]}"}"
        [ -z "$term" ] && continue
        while IFS= read -r hit; do
            report "$hit: matches '$term' from .private-terms"
        done < <(grep -HniF -- "$term" "${files[@]}" 2>/dev/null | cut -d: -f1,2)
    done < "$TERMS_FILE"
fi

if [ "$found" -eq 0 ]; then
    echo "no private data found in ${#files[@]} files"
else
    echo "private data check FAILED -- see above" >&2
fi
exit "$found"
