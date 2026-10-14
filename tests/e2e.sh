#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# End-to-end test: a real install into ~/.ssh, then every write path.
#
#   SSH_FLEET_E2E=1 tests/e2e.sh
#
# !! This REPLACES ~/.ssh/config and ~/.ssh/config.d (existing ones are moved
#    to a backup directory by install.sh). Run it only on a disposable machine:
#    CI, or a container -- see CONTRIBUTING.md. It opens no network connections.
# -----------------------------------------------------------------------------
set -uo pipefail

if [ "${SSH_FLEET_E2E:-}" != 1 ]; then
    echo "refusing to run: this test installs into ~/.ssh. Set SSH_FLEET_E2E=1 on a disposable machine." >&2
    exit 2
fi

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Work on a copy, so the examples copied into config.d never land in the
# checkout being tested.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/ssh-fleet"
cp -a "$SRC" "$REPO"
rm -f "$REPO"/config.d/00-local.conf
cp "$REPO"/examples/config.d/*.conf "$REPO/config.d/"
export NO_COLOR=1 SSH_MENU_STATE="$WORK/menu"

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; fail=$((fail+1)); }
run() {  # run <label> <command...>: pass if it exits 0
    local label="$1"; shift
    local out; out=$("$@" 2>&1) && ok "$label" || bad "$label" "$out"
}

echo "== install =="
run "install.sh (link mode) verifies an alias" "$REPO/scripts/install.sh"
[ "$(readlink -f ~/.ssh/config.d)" = "$(readlink -f "$REPO/config.d")" ] \
    && ok 'config.d in ~/.ssh is a symlink to the repo' || bad 'config.d in ~/.ssh is a symlink to the repo'
[ "$(stat -c %a "$REPO/config.d/staging.conf")" = 600 ] \
    && ok "config files are 600 after install" || bad "config files are 600 after install"
run "install.sh is idempotent" "$REPO/scripts/install.sh"
run "check.sh passes" "$REPO/scripts/check.sh"

echo "== ssh-manage: add then remove is byte-for-byte =="
F="$REPO/config.d/staging.conf"
before=$(sha256sum <"$F")
run "add-host into an existing purpose" "$REPO/scripts/ssh-manage" add-host staging ceph node4 198.51.100.54 --hostname stg-ceph-04
[ "$(ssh -G staging_ceph_node4 2>/dev/null | awk '$1=="hostname"{print $2}')" = 198.51.100.54 ] \
    && ok "new host resolves" || bad "new host resolves"
[ "$(ssh -G staging_ceph_node4 2>/dev/null | awk '$1=="proxyjump"{print $2}')" = staging_bastion ] \
    && ok "new host inherits zone routing (inserted above the wildcards)" || bad "new host inherits zone routing"
"$REPO/scripts/ssh-find" -1 stg-ceph-04 >/dev/null && ok "new hostname is searchable" || bad "new hostname is searchable"
run "rm-host" bash -c "echo y | '$REPO/scripts/ssh-manage' rm-host staging_ceph_node4"
[ "$(sha256sum <"$F")" = "$before" ] && ok "file restored exactly (existing purpose)" \
    || bad "file restored exactly (existing purpose)" "$(diff "$SRC/examples/config.d/staging.conf" "$F")"

run "add-host into a NEW purpose" "$REPO/scripts/ssh-manage" add-host staging db pg1 198.51.100.70
grep -q '^# db$' "$F" && ok "new purpose gets its own section banner" || bad "new purpose gets its own section banner"
run "rm-host of the last host in that purpose" bash -c "echo y | '$REPO/scripts/ssh-manage' rm-host staging_db_pg1"
[ "$(sha256sum <"$F")" = "$before" ] && ok "file restored exactly (banner removed too)" \
    || bad "file restored exactly (banner removed too)" "$(diff "$SRC/examples/config.d/staging.conf" "$F")"

out=$("$REPO/scripts/ssh-manage" add-host staging k8s master1 198.51.100.99 2>&1) \
    && bad "duplicate alias is refused" "$out" || ok "duplicate alias is refused"
out=$("$REPO/scripts/ssh-manage" add-host staging 'bad name' x 198.51.100.99 2>&1) \
    && bad "invalid names are refused" "$out" || ok "invalid names are refused"

echo "== ssh-manage: environments =="
run "add-env (no bastion, no key)" bash -c "printf '\nn\n' | '$REPO/scripts/ssh-manage' add-env pilot"
run "add-host into the new environment" "$REPO/scripts/ssh-manage" add-host pilot app web1 192.0.2.80
# shellcheck disable=SC2088  # ssh -G prints IdentityFile with the ~ unexpanded
[ "$(ssh -G pilot_app_web1 2>/dev/null | awk '$1=="identityfile"{print $2; exit}')" = '~/.ssh/keys/pilot_ed25519' ] \
    && ok "new environment wires its own key" || bad "new environment wires its own key"
run "rm-env" bash -c "printf 'y\n' | '$REPO/scripts/ssh-manage' rm-env pilot"
[ ! -e "$REPO/config.d/pilot.conf" ] && ok "environment file is gone (kept as a .removed- backup)" \
    || bad "environment file is gone"

echo "== deploy-key.sh --dry-run =="
mkdir -p ~/.ssh/keys && ssh-keygen -q -t ed25519 -N '' -f ~/.ssh/keys/staging_ed25519 -C e2e
out=$("$REPO/scripts/deploy-key.sh" staging --dry-run 2>&1)
grep -q 'Dry run - nothing was contacted.' <<<"$out" && ok "dry run contacts nothing" || bad "dry run contacts nothing" "$out"
grep -q 'staging_sre_gitlab_git (git)' <<<"$out" && ok "git@ service account is skipped" || bad "git@ service account is skipped" "$out"
grep -qE 'staging_\*|staging_k8s_worker\*' <<<"$out" && bad "wildcard blocks are never targets" "$out" \
    || ok "wildcard blocks are never targets"
out=$("$REPO/scripts/check.sh" 2>&1)
grep -q 'staging_ed25519 has NO passphrase' <<<"$out" && ok "check.sh flags a passphrase-less key" \
    || bad "check.sh flags a passphrase-less key" "$out"
rm -f ~/.ssh/keys/staging_ed25519 ~/.ssh/keys/staging_ed25519.pub

echo
printf '== %d passed, %d failed ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
