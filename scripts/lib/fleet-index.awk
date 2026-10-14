# -----------------------------------------------------------------------------
# fleet-index.awk -- one TSV row per concrete host alias in ssh config files
#
#   awk -f fleet-index.awk ~/.ssh/config.d/*.conf
#
# Columns:  alias  env  purpose  server  ip  hostname  status  notes
#           (empty hostname/status/notes are written as "-")
#
# Per-host metadata is read from structured comments inside the Host block.
# ssh ignores comments, so this adds searchable data without affecting how any
# connection behaves:
#
#   Host staging_k8s_master1
#       HostName 198.51.100.31
#       # hostname: stg-k8s-cp-01          -> hostname column
#       # status: not in the live cluster  -> status column (flagged in menus)
#       # anything else                    -> notes column (searchable)
#
# A block is the Host line plus its INDENTED lines. A line at column 0 (a
# section comment, another Host) ends it -- the same boundary ssh-manage uses,
# so section banners are never mistaken for host notes.
# Wildcard patterns, Match blocks, aliases without "_" and real DNS names
# (github.com) are not fleet hosts and are skipped.
# -----------------------------------------------------------------------------
function reset() { n = 0; ip = ""; hn = ""; st = ""; nt = "" }

function flush(   i, a, rest, env, purpose, server, u) {
    if (n == 0 || ip == "") { reset(); return }
    for (i = 1; i <= n; i++) {
        a = cur[i]
        if (a ~ /\./) continue
        u = index(a, "_")
        if (u == 0) continue
        env  = substr(a, 1, u - 1)
        rest = substr(a, u + 1)
        u = index(rest, "_")
        if (u > 0) { purpose = substr(rest, 1, u - 1); server = substr(rest, u + 1) }
        else       { purpose = "-"; server = rest }
        # "-" rather than an empty field: bash treats a tab in IFS as whitespace,
        # so two adjacent tabs collapse and every later column shifts left.
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", a, env, purpose, server, ip,
               (hn == "" ? "-" : hn), (st == "" ? "-" : st), (nt == "" ? "-" : nt)
    }
    reset()
}

BEGIN { reset(); inblock = 0 }

FNR == 1 { flush(); inblock = 0 }            # a block never spans two files

/^[ \t]*[Hh][Oo][Ss][Tt][ \t]/ || /^[ \t]*[Mm][Aa][Tt][Cc][Hh][ \t]/ {
    flush()
    if (tolower($1) == "host")
        for (i = 2; i <= NF; i++) if ($i !~ /[*?!]/) cur[++n] = $i
    inblock = 1
    next
}

/^[^ \t]/ { flush(); inblock = 0; next }     # column-0 line ends the block

!inblock { next }

tolower($1) == "hostname" { ip = $2; next }

/^[ \t]+#/ {
    t = $0
    sub(/^[ \t]+#[ \t]*/, "", t)
    gsub(/\t/, " ", t)
    lt = tolower(t)
    if (lt ~ /^hostname:/)    { sub(/^[^:]*:[ \t]*/, "", t); sub(/[ \t]+$/, "", t); hn = t }
    else if (lt ~ /^status:/) { sub(/^[^:]*:[ \t]*/, "", t); st = t }
    else if (t != "")         { nt = (nt == "" ? t : nt " | " t) }
}

END { flush() }
