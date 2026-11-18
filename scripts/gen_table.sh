#!/usr/bin/env bash
# Build the followers table in README.md (between marker comments) from data/users/*.
# Existing "Status" and "date" values in the README are preserved; new rows are blank.
# Groups: administrators, then adopters, then contact pending (yellow), then need org (blue), then no contact info (red dot; adopters stay green), then individuals (black dot, not eligible);
# within each group folks from the same org are together
# (alphabetical by org, no-org last, original order kept within an org).
# Dots are computed: green = adopter (data/ADOPTERS.md), purple = administrative (metadata.json "role"),
# red = no contact info (no e-mail, linked-in, x, mastodon or bluesky),
# yellow = contact pending (has contact info but no other status),
# blue = need org (has a contact method but no org; green/purple win),
# black = individual, not eligible (no org and no contact method; CNCF adopters are organizations; green/purple win).
# Any other text in the status cell is preserved.
set -euo pipefail

DATA_DIR="${DATA_DIR:-data}"
README="${README:-README.md}"
BEGIN='<!-- followers-table:begin -->'
END='<!-- followers-table:end -->'
SBEGIN='<!-- status-table:begin -->'
SEND='<!-- status-table:end -->'

# Preserve statuses and dates already in README: login -> status, login -> date
declare -A STATUS DATE
if [ -f "$README" ]; then
  # Status is column 6 and date column 7 (awk fields $7/$8 after the leading "|"; date is absent in older READMEs);
  # login is the first "[login](https://github.com/login)" link
  while IFS= read -r line; do
    login=$(sed -E 's/^[^[]*\[([^]]+)\]\(https:\/\/github\.com\/.*/\1/' <<<"$line")
    st=$(awk -F'|' '{gsub(/^ +| +$/,"",$7); print $7}' <<<"$line")
    dt=$(awk -F'|' '{gsub(/^ +| +$/,"",$8); print $8}' <<<"$line")
    dt="${dt//<small>/}"; dt="${dt//<\/small>/}"
    [ -n "$login" ] && [ -n "$st" ] && STATUS["$login"]="$st"
    [ -n "$login" ] && [ -n "$dt" ] && DATE["$login"]="$dt"
  done < <(sed -n "/$BEGIN/,/$END/p" "$README" | grep -E '\[[^]]+\]\(https://github\.com/')
fi

METADATA="${METADATA:-$DATA_DIR/metadata.json}"   # hand-maintained overrides keyed by login
ADOPTERS="${ADOPTERS:-$DATA_DIR/ADOPTERS.md}"
ADOPTER_DOT='🟢'
ADMIN_DOT='🟣'
NOCONTACT_DOT='🔴'
PENDING_DOT='🟡'
NEEDORG_DOT='🔵'
INDIVIDUAL_DOT='⚫'
ADOPTER_DEF='https://github.com/cncf/toc/blob/main/FAQ.md#what-is-the-definition-of-an-adopter'

# Load adopters from "- [Name](url)" lines: names (plus parenthetical) and url hosts
declare -a AD_NAMES=() AD_LABELS=() AD_HOSTS=() AD_HOST_LABELS=()
if [ -f "$ADOPTERS" ]; then
  while IFS= read -r l; do
    name=$(sed -E 's/^- \[([^]]+)\]\(.*/\1/' <<<"$l")
    url=$(sed -E 's/^- \[[^]]+\]\(([^)]*)\).*/\1/' <<<"$l")
    host=$(sed -E 's#^[a-z]+://##; s#/.*$##; s#^www\.##' <<<"$url")
    label=$(sed -E 's/ *\(.*\)//' <<<"$name")
    AD_NAMES+=("$label"); AD_LABELS+=("$label")
    paren=$(sed -nE 's/.*\(([^)]*)\).*/\1/p' <<<"$name")
    [ -n "$paren" ] && { AD_NAMES+=("$paren"); AD_LABELS+=("$label"); }
    AD_HOSTS+=("$host"); AD_HOST_LABELS+=("$label")
  done < <(grep -E '^- \[[^]]+\]\(' "$ADOPTERS")
fi

# is_adopter org login email blog -> 0 if any adopter name/domain matches;
# sets ADOPTER_MATCH to the matched adopter's name
is_adopter() {
  local hay words dom a ca i
  ADOPTER_MATCH=""
  dom="${3#*@}"; [ "$3" = "$dom" ] && dom=""
  hay="$1 $2 $dom $4"
  words=" $(tr -c 'a-z0-9\n' ' ' <<<"${hay,,}" | tr -s ' ') "
  local compact="${hay,,}"; compact="${compact//[^a-z0-9]/}"
  for i in "${!AD_NAMES[@]}"; do
    a="${AD_NAMES[$i]}"
    ca="${a,,}"; ca="${ca//[^a-z0-9]/}"
    [ -n "$ca" ] || continue
    if [ "${#ca}" -le 4 ]; then
      [[ "$words" == *" ${a,,} "* ]] && { ADOPTER_MATCH="${AD_LABELS[$i]}"; return 0; }   # short names: whole word only
    else
      [[ "$compact" == *"$ca"* ]] && { ADOPTER_MATCH="${AD_LABELS[$i]}"; return 0; }
    fi
  done
  for i in "${!AD_HOSTS[@]}"; do
    a="${AD_HOSTS[$i]}"
    [ -n "$dom" ] && { [ "${dom,,}" = "$a" ] || [[ "${dom,,}" == *".$a" ]]; } && { ADOPTER_MATCH="${AD_HOST_LABELS[$i]}"; return 0; }
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
stats=$(mktemp)   # one "<dot><TAB><org key>" line per dot per person, for the status table counts
# Rows are emitted as "<group 0|1|2><TAB><no-org 0|1><TAB><org><TAB><row>" so they can be
# sorted: administrators first, then adopters, then by org (people with no org last), original order within an org
while read -r login; do
    [ -n "$login" ] || continue
    u="$DATA_DIR/users/$login.json"; s="$DATA_DIR/users/$login.social.json"
    name=$(jq -r '.name // ""' "$u")
    org=$(normalize_org "$(jq -r '.company // ""' "$u")")
    email=$(jq -r '.email // ""' "$u")
    # Hand-maintained metadata (data/metadata.json) overrides GitHub values: name, org, email, linkedin
    meta_li=""; m_role=""
    if [ -f "$METADATA" ]; then
      # Unit separator (not whitespace) so empty fields are not collapsed by read
      IFS=$'\x1f' read -r m_name m_org m_email meta_li m_role < <(jq -r --arg l "$login" \
        '(.[$l] // {}) | [.name // "", .org // "", .email // "", .linkedin // "", .role // ""] | join("\u001f")' "$METADATA")
      [ -n "$m_name" ] && name="$m_name"
      [ -n "$m_org" ] && org="$m_org"
      [ -n "$m_email" ] && email="$m_email"
    fi
    li=$(jq -r '[.[] | select(.provider=="linkedin") | .url][0] // ""' "$s")
    if [ -z "$li" ]; then
      li=$(jq -r 'if ((.blog // "") | test("linkedin\\.com"; "i")) then .blog else "" end' "$u")
    fi
    [ -n "$meta_li" ] && li="$meta_li"
    blog=$(jq -r '.blog // ""' "$u")
    status="${STATUS[$login]:-}"
    status="${status//$ADOPTER_DOT/}"; status="${status//$ADMIN_DOT/}"; status="${status//$NOCONTACT_DOT/}"; status="${status//$PENDING_DOT/}"; status="${status//$NEEDORG_DOT/}"; status="${status//$INDIVIDUAL_DOT/}"   # dots are recomputed
    status="${status#"${status%%[![:space:]]*}"}"
    dots=""
    if is_adopter "$org" "$login" "$email" "$blog"; then
      dots="$ADOPTER_DOT"
      # No company on the profile: interpolate the org from the matched adopter
      [ -z "$org" ] && org=$(normalize_org "$ADOPTER_MATCH")
    fi
    [ "$m_role" = "administrative" ] && dots="$dots$ADMIN_DOT"   # order: adopter, then admin
    status="$dots${status:+ $status}"
    # Single contact method, in order of preference: e-mail, linked-in, x, mastodon, bluesky
    contact=""
    tw=$(jq -r '[.[] | select(.provider=="twitter") | .url][0] // ""' "$s")
    if [ -z "$tw" ]; then
      tw_user=$(jq -r '.twitter_username // ""' "$u")
      [ -n "$tw_user" ] && tw="https://x.com/$tw_user"
    fi
    ma=$(jq -r '[.[] | select(.provider=="mastodon") | .url][0] // ""' "$s")
    bs=$(jq -r '[.[] | select(.provider=="bluesky") | .url][0] // ""' "$s")
    if [ -n "$email" ]; then
      # U+200B before "@" lets long e-mail addresses wrap, keeping the table narrow
      contact="[${email/@/$'\u200b'@}](mailto:$email)"
    else
      for pair in "linked-in|$li" "x|$tw" "mastodon|$ma" "bluesky|$bs"; do
        [ -n "${pair#*|}" ] && { contact="[${pair%%|*}](${pair#*|})"; break; }
      done
    fi
    key=2; [[ "$status" == *"$ADOPTER_DOT"* ]] && key=1; [[ "$status" == *"$ADMIN_DOT"* ]] && key=0
    if [ -z "$org" ] && [ -z "$dots" ]; then
      if [ -n "$contact" ]; then
        # No org but has a contact method: need org (blue), sorted after contact pending
        status="$NEEDORG_DOT${status#"$dots"}"
        key=3
      else
        # Individual (no org, no contact), not eligible: black dot, sorted last; adopters (green) and administrators (purple) win
        status="$INDIVIDUAL_DOT${status#"$dots"}"
        key=5
      fi
    # No contact info: red dot (after the other dots), sorted after need org; adopters (green) win
    elif [ -z "$contact" ] && [[ "$status" != *"$ADOPTER_DOT"* ]]; then
      status="$dots$NOCONTACT_DOT${status#"$dots"}"
      key=4
    fi
    # Has contact info but no other status: contact pending (yellow)
    [ -n "$contact" ] && [ -z "${status//[[:space:]]/}" ] && status="$PENDING_DOT"
    noorg=0; [ -z "$org" ] && noorg=1
    orgkey=$(tr -d '\t' <<<"${org,,}")
    for d in "$ADMIN_DOT" "$ADOPTER_DOT" "$PENDING_DOT" "$NEEDORG_DOT" "$NOCONTACT_DOT" "$INDIVIDUAL_DOT"; do
      [[ "$status" == *"$d"* ]] && printf '%s\t%s\n' "$d" "$orgkey" >> "$stats"
    done
    printf '%s\t%s\t%s\t| $NUM | %s | %s | %s | %s | %s | %s |\n' "$key" "$noorg" "$orgkey" "$(sm "[$login](https://github.com/$login)")" "$(sm "$(esc "$name")")" "$(sm "$(esc "$org")")" "$(sm "$contact")" "$status" "$(sm "${DATE[$login]:-}")"
done < "$DATA_DIR/followers.txt" > "$rows"
{
  echo "| <small>num</small> | <small>id</small> | <small>name</small> | <small>org</small> | <small>contact</small> | <small>status</small> | <small>date</small> |"
  echo "|----:|----|------|-----|---------|--------|------|"
  sort -s -t $'\t' -k1,1n -k2,2n -k3,3 "$rows" | cut -f4- | awk '{n++; sub(/\$NUM/, n); print}'
} > "$table"
rm -f "$rows"

# Status table: for each dot, org count = unique orgs, person count = persons with no org
count_org()    { awk -F'\t' -v d="$1" '$1==d && $2!="" && !seen[$2]++ {n++} END {print n+0}' "$stats"; }
count_person() { awk -F'\t' -v d="$1" '$1==d && $2=="" {n++} END {print n+0}' "$stats"; }
status_table=$(mktemp)
{
  echo "| status | meaning | org count<sup>1</sup> | person count<sup>2</sup> |"
  echo "|:------:|---------|----------------------:|-------------------------:|"
  for row in "$ADMIN_DOT|administrative" "$ADOPTER_DOT|adopter" "$PENDING_DOT|contact pending" "$NEEDORG_DOT|contact pending, need org" "$NOCONTACT_DOT|no contact info" "$INDIVIDUAL_DOT|individual, not eligible<sup>3</sup>"; do
    echo "| ${row%%|*} | ${row#*|} | $(count_org "${row%%|*}") | $(count_person "${row%%|*}") |"
  done
  echo
  echo "<sup>1</sup> org count: number of unique orgs among the people with that status."
  echo
  echo "<sup>2</sup> person count: number of people with that status who are not in an org (no org listed)."
  echo
  echo "<sup>3</sup> individual, not eligible: a person with no org listed and no contact method. The CNCF TOC FAQ [defines an adopter]($ADOPTER_DEF) as an organization (\"any organization that currently and actively, successfully leverages that project...\"), so an individual is not eligible to be listed in ADOPTERS.md."
} > "$status_table"
rm -f "$stats"

# replace(file, begin-marker, end-marker, content-file): swap what is between the markers
replace_block() {
  local o; o=$(mktemp)
  awk -v b="$2" -v e="$3" -v t="$4" '
    $0==b {print; while ((getline l < t) > 0) print l; skip=1; next}
    $0==e {skip=0}
    !skip {print}' "$1" > "$o"
  mv "$o" "$1"
}

if grep -qF "$BEGIN" "$README"; then
  replace_block "$README" "$BEGIN" "$END" "$table"
else
  { cat "$README"; printf '\n## Followers\n\n%s\n' "$BEGIN"; cat "$table"; printf '%s\n' "$END"; } > "$README.new"
  mv "$README.new" "$README"
fi
grep -qF "$SBEGIN" "$README" && replace_block "$README" "$SBEGIN" "$SEND" "$status_table"
rm -f "$table" "$status_table"
echo "Updated $README"
