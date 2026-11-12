#!/usr/bin/env bash
# Build the followers table in README.md (between marker comments) from data/users/*.
# Existing "Status" values in the README are preserved; new rows are blank.
# Adopters are listed first; within each group folks from the same org are together
# (alphabetical by org, no-org last, original order kept within an org).
# A green dot (adopter) is computed from data/ADOPTERS.md and overrides a stored value.
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

ADOPTERS="${ADOPTERS:-$DATA_DIR/ADOPTERS.md}"
ADOPTER_DOT='🟢'

# Load adopters from "- [Name](url)" lines: names (plus parenthetical) and url hosts
declare -a AD_NAMES=() AD_HOSTS=()
if [ -f "$ADOPTERS" ]; then
  while IFS= read -r l; do
    name=$(sed -E 's/^- \[([^]]+)\]\(.*/\1/' <<<"$l")
    url=$(sed -E 's/^- \[[^]]+\]\(([^)]*)\).*/\1/' <<<"$l")
    host=$(sed -E 's#^[a-z]+://##; s#/.*$##; s#^www\.##' <<<"$url")
    AD_NAMES+=("$(sed -E 's/ *\(.*\)//' <<<"$name")")
    paren=$(sed -nE 's/.*\(([^)]*)\).*/\1/p' <<<"$name")
    [ -n "$paren" ] && AD_NAMES+=("$paren")
    AD_HOSTS+=("$host")
  done < <(grep -E '^- \[[^]]+\]\(' "$ADOPTERS")
fi

# is_adopter org login email blog -> 0 if any adopter name/domain matches
is_adopter() {
  local hay words dom a ca
  dom="${3#*@}"; [ "$3" = "$dom" ] && dom=""
  hay="$1 $2 $dom $4"
  words=" $(tr -c 'a-z0-9\n' ' ' <<<"${hay,,}" | tr -s ' ') "
  local compact="${hay,,}"; compact="${compact//[^a-z0-9]/}"
  for a in "${AD_NAMES[@]}"; do
    ca="${a,,}"; ca="${ca//[^a-z0-9]/}"
    [ -n "$ca" ] || continue
    if [ "${#ca}" -le 4 ]; then
      [[ "$words" == *" ${a,,} "* ]] && return 0   # short names: whole word only
    else
      [[ "$compact" == *"$ca"* ]] && return 0
    fi
  done
  for a in "${AD_HOSTS[@]}"; do
    [ -n "$dom" ] && { [ "${dom,,}" = "$a" ] || [[ "${dom,,}" == *".$a" ]]; } && return 0
  done
  return 1
}

# Normalize org name variants (e.g. "Redhat", "@RedHatOfficial", "IBM Research - Tokyo")
normalize_org() {
  local o="${1,,}"
  if [[ "$o" =~ red[[:space:]_-]?hat ]]; then echo "Red Hat"
  elif [[ "$o" =~ (^|[^a-z0-9])ibm([^a-z0-9]|$) || "$o" == *"international business machines"* ]]; then echo "IBM"
  else echo "$1"; fi
}

esc() { sed -e 's/|/\\|/g' <<<"$1"; }
# Smaller font (GitHub strips style attributes, but allows <small>); empty stays empty
sm() { [ -n "$1" ] && printf '<small>%s</small>' "$1" || true; }

table=$(mktemp)
rows=$(mktemp)
# Rows are emitted as "<adopter 0|1><TAB><no-org 0|1><TAB><org><TAB><row>" so they can be
# sorted: adopters first, then by org (people with no org last), original order within an org
while read -r login; do
    [ -n "$login" ] || continue
    u="$DATA_DIR/users/$login.json"; s="$DATA_DIR/users/$login.social.json"
    name=$(jq -r '.name // ""' "$u")
    org=$(normalize_org "$(jq -r '.company // ""' "$u")")
    email=$(jq -r '.email // ""' "$u")
    li=$(jq -r '[.[] | select(.provider=="linkedin") | .url][0] // ""' "$s")
    if [ -z "$li" ]; then
      li=$(jq -r 'if ((.blog // "") | test("linkedin\\.com"; "i")) then .blog else "" end' "$u")
    fi
    blog=$(jq -r '.blog // ""' "$u")
    status="${STATUS[$login]:-}"
    [ "$status" = "$ADOPTER_DOT" ] && status=""   # dot is recomputed from ADOPTERS.md
    is_adopter "$org" "$login" "$email" "$blog" && status="$ADOPTER_DOT"
    contact=""
    # U+200B before "@" lets long e-mail addresses wrap, keeping the table narrow
    [ -n "$email" ] && contact="[${email/@/$'\u200b'@}](mailto:$email)"
    if [ -n "$li" ]; then
      contact="${contact:+$contact<br>}[linked-in]($li)"
    fi
    key=1; [ "$status" = "$ADOPTER_DOT" ] && key=0
    noorg=0; [ -z "$org" ] && noorg=1
    orgkey=$(tr -d '\t' <<<"${org,,}")
    printf '%s\t%s\t%s\t| $NUM | %s | %s | %s | %s | %s |\n' "$key" "$noorg" "$orgkey" "$(sm "[$login](https://github.com/$login)")" "$(sm "$(esc "$name")")" "$(sm "$(esc "$org")")" "$(sm "$contact")" "$status"
done < "$DATA_DIR/followers.txt" > "$rows"
{
  echo "| num | id | name | org | contact | status |"
  echo "|----:|----|------|-----|---------|--------|"
  sort -s -t $'\t' -k1,1n -k2,2n -k3,3 "$rows" | cut -f4- | awk '{n++; sub(/\$NUM/, n); print}'
} > "$table"
rm -f "$rows"

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
