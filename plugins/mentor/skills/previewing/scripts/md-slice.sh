#!/usr/bin/env bash
# md-slice.sh — print parts of a Markdown file by heading or by table-row number, so a run
# reads the slice it needs instead of the whole file. Headings inside fenced code are ignored.
#
#   md-slice.sh index   FILE            line, level, bytes and text of every heading
#   md-slice.sh section FILE ERE...     each section whose heading text matches an ERE
#                                       (heading through the line before the next heading
#                                       of the same or a higher level)
#   md-slice.sh rows    FILE N|N-M...   table rows whose first cell is N, under their header
#
# Each printed chunk starts with "<!-- md-slice FILE Lstart-Lend -->". Exit 3 when a pattern
# or row matched nothing (the matches that were found are still printed), 2 on bad usage.
set -eu

usage() {
  sed -n '4,12p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}
[ $# -ge 2 ] || usage
cmd=$1 file=$2
shift 2
[ -f "$file" ] || { echo "md-slice: no such file: $file" >&2; exit 2; }

case $cmd in
index)
  awk '
    { line[NR] = $0; off[NR] = total; total += length($0) + 1 }
    /^(```|~~~)/ { fence = !fence; next }
    !fence && /^#{1,6} / {
      n++; hl[n] = NR; match($0, /^#+/); lv[n] = RLENGTH
      t = $0; sub(/^#+ +/, "", t); tx[n] = t
    }
    END {
      off[NR + 1] = total
      for (i = 1; i <= n; i++) {
        end = NR + 1
        for (j = i + 1; j <= n; j++) if (lv[j] <= lv[i]) { end = hl[j]; break }
        printf "L%d\t%s\t%dB\t%s\n", hl[i], substr("######", 1, lv[i]), off[end] - off[hl[i]], tx[i]
      }
    }' "$file"
  ;;
section)
  [ $# -ge 1 ] || usage
  awk -v FILE="$file" '
    BEGIN { for (i = 2; i < ARGC; i++) { pat[++np] = ARGV[i]; ARGV[i] = "" } }
    { line[NR] = $0 }
    /^(```|~~~)/ { fence = !fence; next }
    !fence && /^#{1,6} / {
      n++; hl[n] = NR; match($0, /^#+/); lv[n] = RLENGTH
      t = $0; sub(/^#+ +/, "", t); tx[n] = t
    }
    END {
      last = 0; miss = 0
      for (p = 1; p <= np; p++) hit[p] = 0
      for (i = 1; i <= n; i++) {
        want = 0
        for (p = 1; p <= np; p++) if (tx[i] ~ pat[p]) { want = 1; hit[p] = 1 }
        if (!want || hl[i] < last) continue
        end = NR + 1
        for (j = i + 1; j <= n; j++) if (lv[j] <= lv[i]) { end = hl[j]; break }
        printf "<!-- md-slice %s L%d-%d -->\n", FILE, hl[i], end - 1
        for (k = hl[i]; k < end; k++) print line[k]
        last = end
      }
      for (p = 1; p <= np; p++) if (!hit[p]) { print "md-slice: no heading matches: " pat[p] > "/dev/stderr"; miss = 1 }
      exit miss ? 3 : 0
    }' "$file" "$@"
  ;;
rows)
  [ $# -ge 1 ] || usage
  awk -v FILE="$file" '
    BEGIN {
      for (i = 2; i < ARGC; i++) {
        a = ARGV[i]; ARGV[i] = ""
        if (a ~ /^[0-9]+-[0-9]+$/) { split(a, r, "-"); for (k = r[1] + 0; k <= r[2] + 0; k++) want[k] = 1 }
        else if (a ~ /^[0-9]+$/) want[a + 0] = 1
        else { print "md-slice: not a row number: " a > "/dev/stderr"; bad = 1 }
      }
    }
    { line[NR] = $0 }
    END {
      top = 0
      for (k = 1; k <= NR; k++) {
        if (line[k] !~ /^\|/) { top = 0; continue }
        if (!top) top = k
        c = line[k]; sub(/^\| */, "", c); sub(/ *\|.*$/, "", c)
        if (c ~ /^[0-9]+$/ && (c + 0) in want) {
          if (shown != top) { printf "<!-- md-slice %s table L%d -->\n%s\n%s\n", FILE, top, line[top], line[top + 1]; shown = top }
          printf "<!-- md-slice %s L%d -->\n%s\n", FILE, k, line[k]
          got[c + 0] = 1
        }
      }
      miss = bad
      for (w in want) if (!(w in got)) { print "md-slice: no row " w > "/dev/stderr"; miss = 1 }
      exit miss ? 3 : 0
    }' "$file" "$@"
  ;;
*) usage ;;
esac
