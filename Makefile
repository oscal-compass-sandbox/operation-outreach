# Download the followers of the oscal-compass GitHub organization into ./data
#
# Usage:
#   make followers          # download followers -> data/followers.json (+ followers.txt)
#   make profiles           # fetch each follower's profile -> data/users/
#   make readme             # regenerate the followers table in README.md
#   make clean              # remove ./data
#
# Optional: export GITHUB_TOKEN to raise the API rate limit (60/h -> 5000/h).
# The token is read from the environment only and is never echoed.

ORG        ?= oscal-compass
DATA_DIR   ?= data
API        := https://api.github.com/users/$(ORG)/followers
PER_PAGE   := 100
FOLLOWERS_JSON := $(DATA_DIR)/followers.json
FOLLOWERS_TXT  := $(DATA_DIR)/followers.txt

.PHONY: followers profiles readme clean
.DELETE_ON_ERROR:

followers: $(FOLLOWERS_TXT)

$(FOLLOWERS_TXT): $(FOLLOWERS_JSON)
	jq -r '.[].login' $< > $@
	@echo "Wrote $$(wc -l < $@) followers to $@"

# Always refresh: followers change over time
.PHONY: $(FOLLOWERS_JSON)
$(FOLLOWERS_JSON):
	@command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
	@command -v jq   >/dev/null || { echo "jq is required"   >&2; exit 1; }
	@mkdir -p $(DATA_DIR)
	@tmp=$$(mktemp -d) && trap 'rm -rf "$$tmp"' EXIT && \
	page=1 && \
	while :; do \
	  if [ -n "$$GITHUB_TOKEN" ]; then \
	    curl -sS --fail --proto '=https' --tlsv1.2 --max-time 30 \
	      -H "Accept: application/vnd.github+json" \
	      -H "Authorization: Bearer $$GITHUB_TOKEN" \
	      "$(API)?per_page=$(PER_PAGE)&page=$$page" -o "$$tmp/$$page.json" || exit 1; \
	  else \
	    curl -sS --fail --proto '=https' --tlsv1.2 --max-time 30 \
	      -H "Accept: application/vnd.github+json" \
	      "$(API)?per_page=$(PER_PAGE)&page=$$page" -o "$$tmp/$$page.json" || exit 1; \
	  fi; \
	  [ "$$(jq 'length' "$$tmp/$$page.json")" -eq 0 ] && rm -f "$$tmp/$$page.json" && break; \
	  page=$$((page + 1)); \
	done && \
	jq -s 'add // []' "$$tmp"/*.json > $@ 2>/dev/null || echo '[]' > $@
	@echo "Wrote $@"

profiles: followers
	DATA_DIR=$(DATA_DIR) scripts/fetch_profiles.sh

readme: profiles
	DATA_DIR=$(DATA_DIR) scripts/gen_table.sh

clean:
	rm -rf $(DATA_DIR)
