#!/bin/bash
set -euo pipefail

# Example:
# API_URL=http://kiosk.local PIN=1111 REMOTE_BASE_DIR=documents/2026 \
# LOCAL_FILE_1=hello.html LOCAL_FILE_2=materialy/file.bin ./filesystem_examples.sh

API_URL="${API_URL:-${1:-http://kiosk.local}}"
PIN="${PIN:-${2:-1111}}"
REMOTE_BASE_DIR="${REMOTE_BASE_DIR:-${3:-documents/2026}}"
LOCAL_FILE_1="${LOCAL_FILE_1:-${4:-hello.html}}"
LOCAL_FILE_2="${LOCAL_FILE_2:-${5:-materialy/21-Rocket-Loading-Screen-by-Kilian-Maret.jpg}}"

UPLOAD_FILENAME_1="${UPLOAD_FILENAME_1:-$(basename "$LOCAL_FILE_1")}" 
UPLOAD_FILENAME_2="${UPLOAD_FILENAME_2:-$(basename "$LOCAL_FILE_2")}" 

LIST_PATH="${LIST_PATH:-$REMOTE_BASE_DIR}"
CREATE_DIR_PATH="${CREATE_DIR_PATH:-$REMOTE_BASE_DIR/api-demo-dir}"
MOVE_TARGET_DIR="${MOVE_TARGET_DIR:-$REMOTE_BASE_DIR/moved}"
CHUNK_TARGET_DIR="${CHUNK_TARGET_DIR:-$REMOTE_BASE_DIR/chunked}"

UPLOAD_PATH_1="$REMOTE_BASE_DIR/$UPLOAD_FILENAME_1"
MOVE_TARGET_PATH="${MOVE_TARGET_PATH:-$MOVE_TARGET_DIR/$UPLOAD_FILENAME_1}"
RENAME_TARGET_PATH="${RENAME_TARGET_PATH:-$MOVE_TARGET_DIR/renamed-$UPLOAD_FILENAME_1}"
DOWNLOAD_SOURCE_PATH="${DOWNLOAD_SOURCE_PATH:-$RENAME_TARGET_PATH}"
DOWNLOAD_DEST="${DOWNLOAD_DEST:-/tmp/$(basename "$DOWNLOAD_SOURCE_PATH")}" 
CHUNK_REMOTE_FILENAME="${CHUNK_REMOTE_FILENAME:-chunked-$UPLOAD_FILENAME_2}"
CHUNK_REMOTE_PATH="$CHUNK_TARGET_DIR/$CHUNK_REMOTE_FILENAME"
CHUNK_SIZE="${CHUNK_SIZE:-524288}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

log_step() {
  echo
  echo "== $1 =="
}

api_json() {
  local method="$1"
  local endpoint="$2"
  local data="${3:-}"

  if [[ -n "$data" ]]; then
    curl -sS -X "$method" "$API_URL$endpoint" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d "$data"
  else
    curl -sS -X "$method" "$API_URL$endpoint" \
      -H "Authorization: Bearer $TOKEN"
  fi
}

require_cmd curl
require_cmd jq
require_cmd split

[[ -f "$LOCAL_FILE_1" ]] || { echo "Missing file: $LOCAL_FILE_1" >&2; exit 1; }
[[ -f "$LOCAL_FILE_2" ]] || { echo "Missing file: $LOCAL_FILE_2" >&2; exit 1; }

log_step "Login"
LOGIN_RESPONSE=$(curl -sS -X POST "$API_URL/api/login" \
  -H "Content-Type: application/json" \
  -d "{\"pin\":\"$PIN\"}")
TOKEN=$(echo "$LOGIN_RESPONSE" | jq -r '.token')

if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
  echo "Login failed"
  echo "$LOGIN_RESPONSE"
  exit 1
fi

echo "Token acquired"

log_step "Upload reference file"
UPLOAD_RESPONSE=$(curl -sS -X POST "$API_URL/api/files/upload" \
  -H "Authorization: Bearer $TOKEN" \
  -F "file=@$LOCAL_FILE_1" \
  -F "filename=$UPLOAD_FILENAME_1" \
  -F "path=$REMOTE_BASE_DIR")
echo "$UPLOAD_RESPONSE" | jq .

log_step "Create directory: /api/files/dir POST"
api_json POST "/api/files/dir" "{\"path\":\"$CREATE_DIR_PATH\"}" | jq .

log_step "List files: /api/files/list GET"
curl -sS -G "$API_URL/api/files/list" \
  -H "Authorization: Bearer $TOKEN" \
  --data-urlencode "path=$LIST_PATH" \
  --data-urlencode "page=1" \
  --data-urlencode "per_page=50" \
  --data-urlencode "sort=name" \
  --data-urlencode "order=asc" | jq .

log_step "File info: /api/files/info GET"
curl -sS -G "$API_URL/api/files/info" \
  -H "Authorization: Bearer $TOKEN" \
  --data-urlencode "path=$UPLOAD_PATH_1" | jq .

log_step "Move file: /api/files/move POST"
api_json POST "/api/files/move" "{\"src\":\"$UPLOAD_PATH_1\",\"dst\":\"$MOVE_TARGET_PATH\"}" | jq .

log_step "Rename file: /api/files/rename POST"
api_json POST "/api/files/rename" "{\"src\":\"$MOVE_TARGET_PATH\",\"dst\":\"$RENAME_TARGET_PATH\"}" | jq .

log_step "Download file: /api/files/download/<path> GET"
mkdir -p "$(dirname "$DOWNLOAD_DEST")"
curl -sS "$API_URL/api/files/download/$DOWNLOAD_SOURCE_PATH" \
  -H "Authorization: Bearer $TOKEN" \
  -o "$DOWNLOAD_DEST"
echo "Downloaded to $DOWNLOAD_DEST"

log_step "Chunk upload: /api/files/upload/chunk POST"
TMP_CHUNK_DIR=$(mktemp -d)
cleanup() {
  rm -rf "$TMP_CHUNK_DIR"
}
trap cleanup EXIT

split -b "$CHUNK_SIZE" -d -a 4 "$LOCAL_FILE_2" "$TMP_CHUNK_DIR/chunk_"
mapfile -t CHUNK_FILES < <(find "$TMP_CHUNK_DIR" -maxdepth 1 -type f | sort)
TOTAL_CHUNKS="${#CHUNK_FILES[@]}"

for idx in "${!CHUNK_FILES[@]}"; do
  CHUNK_RESPONSE=$(curl -sS -X POST "$API_URL/api/files/upload/chunk" \
    -H "Authorization: Bearer $TOKEN" \
    -F "chunk=@${CHUNK_FILES[$idx]}" \
    -F "filename=$CHUNK_REMOTE_FILENAME" \
    -F "chunk_index=$idx" \
    -F "total_chunks=$TOTAL_CHUNKS" \
    -F "path=$CHUNK_TARGET_DIR")
  echo "Chunk $idx/$((TOTAL_CHUNKS - 1)): $CHUNK_RESPONSE"
done

log_step "Delete uploaded chunked file: /api/files/file DELETE"
api_json DELETE "/api/files/file" "{\"path\":\"$CHUNK_REMOTE_PATH\"}" | jq .

log_step "Delete renamed file: /api/files/file DELETE"
api_json DELETE "/api/files/file" "{\"path\":\"$RENAME_TARGET_PATH\"}" | jq .

log_step "Delete created directory: /api/files/dir DELETE"
api_json DELETE "/api/files/dir" "{\"path\":\"$CREATE_DIR_PATH\"}" | jq .

log_step "Delete move target directory: /api/files/dir DELETE"
api_json DELETE "/api/files/dir" "{\"path\":\"$MOVE_TARGET_DIR\"}" | jq .

log_step "Delete chunk target directory: /api/files/dir DELETE"
api_json DELETE "/api/files/dir" "{\"path\":\"$CHUNK_TARGET_DIR\"}" | jq .

echo
echo "All filesystem API examples completed."

