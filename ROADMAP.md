# Roadmap

Ideas that fit the project, roughly in order of usefulness. Each one keeps the
same principles as the existing tools: read the SSH config as the single source
of truth, ask before touching any server, and never handle a secret in `argv`.
Pick one up and open an issue to discuss the approach first.

1. **`ssh-reconcile`** — paste or pipe `kubectl get nodes -o wide` and get a
   drift report against `config.d`: nodes filed under the wrong cluster, wrong
   `# hostname:`, nodes missing from the config, and aliases no longer in the
   cluster. Optionally apply the fixes through `ssh-manage`.
2. **`ssh-inventory`** — run the read-only discovery commands from README §4e
   across a group and emit `alias <TAB> hostname <TAB> role`, ready to review
   and apply.
3. **MobaXterm session importer** — turn a MobaXterm `.ini` export into
   environment files: folders become environments and purposes.
4. **`ssh-run`** — one command across a group in parallel, with a per-host
   summary of exit status and output (the non-interactive sibling of
   `ssh-tmux`).
5. **`ssh-tunnel`** — named port forwards by alias (a dashboard, a registry,
   the Kubernetes API), started and stopped by name.
6. **File transfer helpers** — an `sshfs` mount per alias, or `scp`/`rsync`
   wrappers that complete aliases.
7. **Session logging** — opt-in tmux `pipe-pane` transcripts to dated files for
   `ssh-tmux` sessions.
8. **Portability** — run `ssh-menu` on macOS without GNU `grep -P`, `sort -V`
   and `stat -c`.
