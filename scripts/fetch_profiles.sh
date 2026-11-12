#!/usr/bin/env bash
# Fetch profile + social accounts for each login in data/followers.txt
# into data/users/<login>.json and data/users/<login>.social.json.
# Uses GITHUB_TOKEN from the environment if set (never printed).
set -euo pipefail

DATA_DIR="${DATA_DIR:-data}"
USERS_DIR="$DATA_DIR/users"
mkdir -p "$USERS_DIR"

get() { # url outfile
  local args=(-sS --fail --proto '=https' --tlsv1.2 --max-time 30 -H "Accept: application/vnd.github+json")
  [ -n "${GITHUB_TOKEN:-}" ] && args+=(-H "Authorization: Bearer $GITHUB_TOKEN")
  curl "${args[@]}" "$1" -o "$2.tmp" && mv "$2.tmp" "$2"
}

while read -r login; do
  [ -n "$login" ] || continue
  [ -s "$USERS_DIR/$login.json" ]        || get "https://api.github.com/users/$login" "$USERS_DIR/$login.json"
  [ -s "$USERS_DIR/$login.social.json" ] || get "https://api.github.com/users/$login/social_accounts" "$USERS_DIR/$login.social.json"
done < "$DATA_DIR/followers.txt"
echo "Profiles in $USERS_DIR: $(ls "$USERS_DIR"/*.json | grep -vc '\.social\.json')"
