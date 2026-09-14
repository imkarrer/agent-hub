#!/usr/bin/env bash
# The results/all.jsonl bench.sh appends to, as a table. Pipe through
# `grep b3-` etc. to see one batch.
cd "$(dirname "$0")"
printf '%-24s %-11s %-8s %3s %5s %5s %2s %4s %8s %6s  %s\n' name build test t b ub fa mmap tok/s std args
jq -r '[.name,.build,.test,.t,.b,.ub,.fa,.mmap,.avg_ts,.std,.args]|@tsv' results/all.jsonl \
  | while IFS=$'\t' read -r n bu te t b ub fa mm ts sd a; do
      printf '%-24s %-11s %-8s %3s %5s %5s %2s %4s %8s %6s  %s\n' "$n" "$bu" "$te" "$t" "$b" "$ub" "$fa" "$mm" "$ts" "$sd" "$a"
    done
