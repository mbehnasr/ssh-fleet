# -----------------------------------------------------------------------------
# fleet-search.awk -- rank fleet-index rows against a free-text query
#
#   awk -f fleet-index.awk config.d/*.conf | awk -v q="k8s worker" -f fleet-search.awk
#
# Output: score<TAB>row, unsorted  ->  sort -t$'\t' -k1,1nr -k2,2 | cut -f2-
#
# Every whitespace-separated term must appear somewhere in the row (AND),
# case-insensitively: alias, env, purpose, server, IP, hostname, status, notes.
# Ranking puts what you most likely meant first:
#     exact alias / IP / hostname   100
#     prefix of alias/IP/hostname    20   ("198.51.100.3", "stg-k8s")
#     substring of those             5
#     only in env/status/notes       1   ("osd", "not a node")
# An empty query matches everything with score 0.
#
# -v strict=1 drops rows where any term matched ONLY in notes or status.
# Use it when the result drives an action (connect, tmux panes): a note like
# "VIP, listed with the workers" must not turn a search for workers into a
# pane on a VIP.
# -----------------------------------------------------------------------------
BEGIN {
    FS = OFS = "\t"
    nt = split(tolower(q), term, /[ \t]+/)
}
{
    alias = tolower($1); server = tolower($4); ip = $5; hn = tolower($6)
    hay = tolower($1 " " $2 " " $3 " " $4 " " $5 " " $6 " " $7 " " $8)
    score = 0; weak = 0
    for (i = 1; i <= nt; i++) {
        t = term[i]
        if (t == "") continue
        if (index(hay, t) == 0) next
        if (t == alias || t == ip || t == hn)                         score += 100
        else if (index(alias, t) == 1 || index(ip, t) == 1 ||
                 index(hn, t) == 1    || index(server, t) == 1)       score += 20
        else if (index(alias, t) || index(ip, t) || index(hn, t))     score += 5
        else                                                        { score += 1; weak = 1 }
    }
    if (strict && weak) next
    print score, $0
}
