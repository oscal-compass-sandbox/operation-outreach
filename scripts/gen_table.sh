#!/usr/bin/env bash
# Build the followers table in README.md (between marker comments) from data/users/*.
# Existing "Status" values in the README are preserved; new rows are blank.
set -euo pipefail

DATA_DIR="${DATA_DIR:-data}"
README="${README:-README.md}"
BEGIN='<!-- followers-table:begin -->'
END='<!-- followers-table:end -->'

# Preserve statuses already in README: login -> status
declare -A STATUS
if [ -f "$README" ]; then
  # Status is the last column; login is the first "[login](https://github.com/login)" link
  while IFS= read -r line; do
    login=$(sed -E 's/^[^[]*\[([^]]+)\]\(https:\/\/github\.com\/.*/\1/' <<<"$line")
    st=$(sed -E 's/ *\| *$//; s/^.*\| *//' <<<"$line")
    [ -n "$login" ] && [ -n "$st" ] && STATUS["$login"]="$st"
  done < <(sed -n "/$BEGIN/,/$END/p" "$README" | grep -E '\[[^]]+\]\(https://github\.com/')
fi

esc() { sed -e 's/|/\\|/g' <<<"$1"; }

table=$(mktemp)
{
  echo "| num | id | name | org | contact | status |"
  echo "|----:|----|------|-----|---------|--------|"
  num=0
  while read -r login; do
    [ -n "$login" ] || continue
    num=$((num + 1))
    u="$DATA_DIR/users/$login.json"; s="$DATA_DIR/users/$login.social.json"
    name=$(jq -r '.name // ""' "$u")
    org=$(jq -r '.company // ""' "$u")
    email=$(jq -r '.email // ""' "$u")
    li=$(jq -r '[.[] | select(.provider=="linkedin") | .url][0] // ""' "$s")
    if [ -z "$li" ]; then
      li=$(jq -r 'if ((.blog // "") | test("linkedin\\.com"; "i")) then .blog else "" end' "$u")
    fi
    contact=""
    [ -n "$email" ] && contact="[$email](mailto:$email)"
    if [ -n "$li" ]; then
      contact="${contact:+$contact<br>}[linked-in]($li)"
    fi
    echo "| $num | [$login](https://github.com/$login) | $(esc "$name") | $(esc "$org") | $contact | ${STATUS[$login]:-} |"
  done < "$DATA_DIR/followers.txt"
} > "$table"

out=$(mktemp)
if grep -qF "$BEGIN" "$README"; then
  awk -v b="$BEGIN" -v e="$END" -v t="$table" '
    $0==b {print; while ((getline l < t) > 0) print l; skip=1; next}
    $0==e {skip=0}
    !skip {print}' "$README" > "$out"
else
  { cat "$README"; printf '\n## Followers\n\n%s\n' "$BEGIN"; cat "$table"; printf '%s\n' "$END"; } > "$out"
fi
mv "$out" "$README"; rm -f "$table"
echo "Updated $README"
