#!/usr/bin/env bash
set -euo pipefail

readonly README="README.md"
readonly MARKER_START="<!-- PR_TRACKER_START -->"
readonly MARKER_END="<!-- PR_TRACKER_END -->"
readonly GH_USER="faizanfirdousi"
readonly RECENT_LIMIT=3

log() {
  echo "[update-prs] $*"
}

fail() {
  echo "[update-prs] ERROR: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

gh_api() {
  local url="$1"
  curl -sf \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$url"
}

gh_search() {
  local query="$1"
  local encoded_query
  encoded_query="$(printf '%s' "$query" | jq -sRr @uri)"
  gh_api "https://api.github.com/search/issues?q=${encoded_query}&per_page=100&sort=updated&order=desc"
}

count_items() {
  local json="$1"
  echo "$json" | jq '.total_count'
}

# Get N most-recent PRs — status resolved inside jq to avoid null/empty TSV ambiguity
recent_prs() {
  local json="$1"
  local limit="$2"
  echo "$json" | jq -r --argjson limit "$limit" '
    .items[:$limit][] |
    [
      .html_url,
      (.repository_url | split("/") | .[-2] + "/" + .[-1]),
      .title,
      (if .pull_request.merged_at != null then "merged"
       elif .state == "open"              then "open"
       else                                   "closed"
       end),
      (.updated_at | split("T")[0])
    ] | @tsv
  '
}

build_pr_rows() {
  local json="$1"
  local limit="$2"
  local rows=""

  # status is a clean string: "open" | "merged" | "closed" — resolved by jq
  while IFS=$'\t' read -r url repo title status date; do
    local badge
    case "$status" in
      merged) badge="![merged](https://img.shields.io/badge/merged-8957e5?style=flat-square&logo=git-merge&logoColor=white)" ;;
      open)   badge="![open](https://img.shields.io/badge/open-238636?style=flat-square&logo=github&logoColor=white)" ;;
      *)      badge="![closed](https://img.shields.io/badge/closed-da3633?style=flat-square&logo=github&logoColor=white)" ;;
    esac

    # Truncate long titles cleanly
    if [[ ${#title} -gt 55 ]]; then
      title="${title:0:52}..."
    fi

    rows+="- **$repo** · [$title]($url) $badge"$'\n'
  done < <(recent_prs "$json" "$limit")

  printf '%s' "$rows"
}

write_section() {
  local raised_json="$1"
  local merged_json="$2"
  local section_file="$3"

  local total_raised total_merged
  total_raised="$(count_items "$raised_json")"
  total_merged="$(count_items "$merged_json")"

  local recent_rows
  recent_rows="$(build_pr_rows "$raised_json" "$RECENT_LIMIT")"

  cat > "$section_file" <<EOF
${MARKER_START}
<p align="left">
  <img src="https://img.shields.io/badge/PRs_Raised-${total_raised}-2088FF?style=flat-square&logo=github&logoColor=white" alt="PRs Raised" />
  <img src="https://img.shields.io/badge/PRs_Merged-${total_merged}-8957e5?style=flat-square&logo=git-merge&logoColor=white" alt="PRs Merged" />
</p>

#### Recent Contributions

${recent_rows}
${MARKER_END}
EOF
}

replace_readme_section() {
  local section_file="$1"
  local tmp_file
  tmp_file="$(mktemp)"

  if grep -qF "$MARKER_START" "$README" && grep -qF "$MARKER_END" "$README"; then
    awk -v section_file="$section_file" -v marker_start="$MARKER_START" -v marker_end="$MARKER_END" '
      $0 == marker_start {
        while ((getline line < section_file) > 0) {
          print line
        }
        close(section_file)
        skip = 1
        next
      }
      $0 == marker_end {
        skip = 0
        next
      }
      !skip {
        print
      }
    ' "$README" > "$tmp_file"
  else
    cat "$README" "$section_file" > "$tmp_file"
  fi

  mv "$tmp_file" "$README"
}

main() {
  require_command curl
  require_command jq

  if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    fail "GITHUB_TOKEN environment variable is not set"
  fi

  if [[ ! -f "$README" ]]; then
    fail "README file not found: $README"
  fi

  log "Fetching PRs raised and merged by ${GH_USER} (parallel)..."
  local raised_file merged_file
  raised_file="$(mktemp)"
  merged_file="$(mktemp)"

  gh_search "type:pr author:${GH_USER} -user:${GH_USER}" > "$raised_file" &
  local pid_raised=$!
  gh_search "type:pr author:${GH_USER} is:merged -user:${GH_USER}" > "$merged_file" &
  local pid_merged=$!

  wait "$pid_raised"  || fail "Failed to fetch PRs raised"
  wait "$pid_merged" || fail "Failed to fetch merged PRs"

  local raised_json merged_json
  raised_json="$(cat "$raised_file")"
  merged_json="$(cat "$merged_file")"
  rm -f "$raised_file" "$merged_file"

  local total_raised total_merged
  total_raised="$(count_items "$raised_json")"
  total_merged="$(count_items "$merged_json")"
  log "Found ${total_raised} PRs raised, ${total_merged} merged"

  local section_file
  section_file="$(mktemp)"
  trap "rm -f '$section_file'" EXIT

  write_section "$raised_json" "$merged_json" "$section_file"
  replace_readme_section "$section_file"

  log "README updated with PR tracker (${total_raised} raised, ${total_merged} merged)"
}

main "$@"
