#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Smoke tests against the example fleet, in a throwaway SSH_DIR.
# Never touches ~/.ssh and opens no network connections.
#
#   tests/smoke.sh
#
# The installed config's Include line is rewritten to point at the temporary
# config.d, so every tool that runs "ssh -F $SSH_DIR/config -G" resolves the
# examples exactly as it would resolve a real installation.
# -----------------------------------------------------------------------------
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export SSH_DIR="$T/ssh" SSH_MENU_STATE="$T/menu" NO_COLOR=1

mkdir -p "$SSH_DIR"/{config.d,keys,cm,known_hosts.d}
chmod 700 "$SSH_DIR" "$SSH_DIR"/*
sed "s|^Include ~/.ssh/config.d/\*.conf|Include $SSH_DIR/config.d/*.conf|" "$REPO/config" > "$SSH_DIR/config"
cp "$REPO"/config.d/forges.conf "$REPO"/examples/config.d/*.conf "$SSH_DIR/config.d/"
chmod 600 "$SSH_DIR/config" "$SSH_DIR"/config.d/*

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; fail=$((fail+1)); }
expect_eq() {  # expect_eq <label> <expected> <actual>
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected: $2"$'\n'"actual:   $3"; fi
}

echo "== config resolves =="
# OpenSSH 10 prints booleans as true/false, 9.x as yes/no: normalise to true/false.
g() { ssh -F "$SSH_DIR/config" -G "$1" 2>/dev/null |
      awk -v k="$2" '$1==k { v = $2; if (v == "yes") v = "true"; else if (v == "no") v = "false"; print v; exit }'; }
expect_eq "staging host resolves to its HostName"      198.51.100.53 "$(g staging_ceph_node3 hostname)"
expect_eq "mgmt zone is one hop"                       staging_bastion "$(g staging_ceph_node3 proxyjump)"
expect_eq "workload zone is two hops"                  staging_bastion,staging_mgmt_jump "$(g staging_k8s_worker1 proxyjump)"
expect_eq "bastion does not jump through itself"       "" "$(g staging_bastion proxyjump)"
expect_eq "per-host User override wins (first match)"  git "$(g staging_sre_gitlab_git user)"
# shellcheck disable=SC2088  # ssh -G prints IdentityFile with the ~ unexpanded
expect_eq "environment key"                            '~/.ssh/keys/staging_ed25519' "$(g staging_k8s_master1 identityfile)"
# ssh -G expands ~ in UserKnownHostsFile (but not in IdentityFile): compare the tail.
expect_eq "per-environment known_hosts"                known_hosts.d/lab "$(g lab_k8s_master01 userknownhostsfile | sed 's|.*/known_hosts\.d/|known_hosts.d/|')"
expect_eq "password environment turns pubkey off"      false "$(g lab_k8s_master01 pubkeyauthentication)"
expect_eq "production refuses unknown host keys"       true "$(g production_k8s_master1 stricthostkeychecking)"
expect_eq "agent forwarding off everywhere"            false "$(g staging_k8s_worker1 forwardagent)"
expect_eq "forge uses git@"                            git "$(g github.com user)"

echo "== check.sh =="
out=$("$REPO/scripts/check.sh" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && grep -q '== 0 error(s)' <<<"$out"; then ok "check.sh reports 0 errors"
else bad "check.sh reports 0 errors" "$out"; fi
grep -q 'lab: password auth by design' <<<"$out" && ok "check.sh recognises the password environment" \
    || bad "check.sh recognises the password environment" "$out"
grep -q 'share HostName' <<<"$out" && bad "git@ alias on a shared address is not a duplicate" "$out" \
    || ok "git@ alias on a shared address is not a duplicate"

echo "== ssh-hosts =="
out=$("$REPO/scripts/ssh-hosts" staging_k8s_worker 2>&1)
expect_eq "ssh-hosts lists one row per worker plus a header" 4 "$(wc -l <<<"$out" | tr -d ' ')"
grep -q 'staging_k8s_worker1 .*stg-k8s-wk-01' <<<"$out" && ok "ssh-hosts shows the real hostname" \
    || bad "ssh-hosts shows the real hostname" "$out"

echo "== fleet index =="
idx=$(awk -f "$REPO/scripts/lib/fleet-index.awk" "$SSH_DIR"/config.d/*.conf)
expect_eq "every row has 8 columns" 8 "$(awk -F'\t' '{print NF}' <<<"$idx" | sort -u)"
expect_eq "32 fleet hosts indexed (github.com excluded)" 32 "$(wc -l <<<"$idx" | tr -d ' ')"
expect_eq "status is parsed" "not a node of the live cluster (kubectl get nodes, 2026-10-01)" \
    "$(awk -F'\t' '$1=="staging_k8s_worker3" {print $7}' <<<"$idx")"
expect_eq "column-0 comments never become host notes" "-" \
    "$(awk -F'\t' '$1=="production_k8s_worker1" {print $8}' <<<"$idx")"

echo "== ssh-find =="
expect_eq "exact hostname"            staging_k8s_master1 "$("$REPO/scripts/ssh-find" -1 stg-k8s-cp-01)"
expect_eq "exact IP"                  lab_k8s_worker01    "$("$REPO/scripts/ssh-find" -1 192.0.2.21)"
expect_eq "AND of several terms"      4 "$("$REPO/scripts/ssh-find" -a lab worker | wc -l | tr -d ' ')"
expect_eq "notes do not drive -a when better matches exist" "" \
    "$("$REPO/scripts/ssh-find" -a lab worker | grep vip)"
expect_eq "status search still works" "lab_k8s_worker04 staging_k8s_worker3" \
    "$("$REPO/scripts/ssh-find" -a "not a node" | sort | paste -sd' ')"
"$REPO/scripts/ssh-find" -1 k8s >/dev/null 2>&1 && bad "-1 fails on an ambiguous query" || ok "-1 fails on an ambiguous query"
"$REPO/scripts/ssh-find" no-such-host >/dev/null 2>&1 && bad "no match exits 1" || ok "no match exits 1"

echo "== ssh-menu (no tty) =="
out=$("$REPO/scripts/ssh-menu" --tree 2>&1)
grep -q '├── lab (11 hosts)' <<<"$out" && grep -q '└── staging (14 hosts)' <<<"$out" \
    && ok "--tree groups hosts by environment" || bad "--tree groups hosts by environment" "$out"
out=$(echo q | "$REPO/scripts/ssh-menu" staging 2>&1)
grep -q 'k8s .* 7 hosts' <<<"$out" && ok "purpose screen counts hosts" || bad "purpose screen counts hosts" "$out"
out=$(echo | "$REPO/scripts/ssh-menu" -s k8s worker 2>&1)
grep -q 'search: k8s worker  (8)' <<<"$out" && ok "search ranks and counts matches" || bad "search ranks and counts matches" "$out"

echo
printf '== %d passed, %d failed ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
