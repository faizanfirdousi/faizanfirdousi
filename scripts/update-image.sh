#!/usr/bin/env bash
set -euo pipefail

readonly README="README.md"
readonly LAST_ID_FILE=".github/unsplash-last-id"
readonly MARKER_START="<!-- DAILY_VISUAL_START -->"
readonly MARKER_END="<!-- DAILY_VISUAL_END -->"
readonly QUERIES=(
   "technology"
  "space"
  "architecture"
  "science"
  "cyberpunk"
  "cityscape"
  "futuristic"
)
readonly UTM_SOURCE="faizanfirdousi"
readonly MAX_RETRIES=5

QUERY=""

log() {
  echo "[update-image] $*"
}

fail() {
  echo "[update-image] ERROR: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

add_utm() {
  local url="$1"

  if [[ -z "$url" || "$url" == "null" ]]; then
    fail "Cannot add UTM parameters to an empty URL"
  fi

  if [[ "$url" == *"utm_source="* ]]; then
    printf '%s' "$url"
    return
  fi

  local separator="?"
  if [[ "$url" == *"?"* ]]; then
    separator="&"
  fi

  printf '%s%sutm_source=%s&utm_medium=referral' "$url" "$separator" "$UTM_SOURCE"
}

select_query() {
  QUERY="${QUERIES[$RANDOM % ${#QUERIES[@]}]}"
  log "Selected query: ${QUERY}"
}

fetch_random_photo() {
  curl -sf \
    -H "Authorization: Client-ID ${UNSPLASH_ACCESS_KEY}" \
    -H "Accept-Version: v1" \
    "https://api.unsplash.com/photos/random?query=${QUERY}&content_filter=high&orientation=landscape"
}

validate_photo_json() {
  local response="$1"

  if ! echo "$response" | jq -e . >/dev/null 2>&1; then
    fail "Unsplash API returned invalid JSON"
  fi

  local image_url photo_id photographer_name photographer_url unsplash_photo_url

  image_url="$(echo "$response" | jq -er '.urls.regular // empty')"
  photo_id="$(echo "$response" | jq -er '.id // empty')"
  photographer_name="$(echo "$response" | jq -er '.user.name // empty')"
  photographer_url="$(echo "$response" | jq -er '.user.links.html // empty')"
  unsplash_photo_url="$(echo "$response" | jq -er '.links.html // empty')"

  if [[ -z "$image_url" || -z "$photo_id" || -z "$photographer_name" || -z "$photographer_url" || -z "$unsplash_photo_url" ]]; then
    fail "Unsplash API response is missing required fields"
  fi
}

get_last_photo_id() {
  if [[ -f "$LAST_ID_FILE" ]]; then
    tr -d '[:space:]' < "$LAST_ID_FILE"
  fi
}

write_section_file() {
  local response="$1"
  local section_file="$2"

  local image_url photo_id photographer_name photographer_url unsplash_photo_url
  local photographer_url_with_utm unsplash_home_url

  image_url="$(echo "$response" | jq -er '.urls.regular')"
  photo_id="$(echo "$response" | jq -er '.id')"
  photographer_name="$(echo "$response" | jq -er '.user.name')"
  photographer_url="$(echo "$response" | jq -er '.user.links.html')"
  unsplash_photo_url="$(echo "$response" | jq -er '.links.html')"

  photographer_url_with_utm="$(add_utm "$photographer_url")"
  unsplash_home_url="$(add_utm "https://unsplash.com/")"

  cat > "$section_file" <<EOF
${MARKER_START}
<div align="center">
  <img
    src="${image_url}"
    alt="Daily highlight"
    style="display: block; margin: 0 auto; max-width: 800px; max-height: 420px; width: 100%; height: auto; object-fit: contain; border-radius: 8px;"
  />

  <p align="center">
    <sub>
      Photo by <a href="${photographer_url_with_utm}">${photographer_name}</a> on
      <a href="${unsplash_home_url}">Unsplash</a>
    </sub>
  </p>
</div>
${MARKER_END}
EOF

  mkdir -p "$(dirname "$LAST_ID_FILE")"
  printf '%s\n' "$photo_id" > "$LAST_ID_FILE"
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

  if [[ -z "${UNSPLASH_ACCESS_KEY:-}" ]]; then
    fail "UNSPLASH_ACCESS_KEY environment variable is not set"
  fi

  if [[ ! -f "$README" ]]; then
    fail "README file not found: $README"
  fi

  select_query

  local last_id="" response="" photo_id="" attempt section_file

  last_id="$(get_last_photo_id)"
  response=""
  photo_id=""

  for ((attempt = 1; attempt <= MAX_RETRIES; attempt++)); do
    if ! response="$(fetch_random_photo)"; then
      fail "Unsplash API request failed"
    fi

    validate_photo_json "$response"
    photo_id="$(echo "$response" | jq -er '.id')"

    if [[ -z "$last_id" || "$photo_id" != "$last_id" ]]; then
      break
    fi

    log "Received duplicate photo ID (${photo_id}), retrying (${attempt}/${MAX_RETRIES})..."
  done

  if [[ -n "$last_id" && "$photo_id" == "$last_id" ]]; then
    log "Could not fetch a different photo after ${MAX_RETRIES} attempts; updating with the same image"
  fi

  section_file="$(mktemp)"
  trap "rm -f '$section_file'" EXIT

  write_section_file "$response" "$section_file"
  replace_readme_section "$section_file"

  log "Updated README with Unsplash photo ${photo_id} (${QUERY})"
}

main "$@"
