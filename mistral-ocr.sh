#!/usr/bin/env bash
# Run Mistral OCR on a local file (PDF or image) and write extracted markdown
# plus any embedded images to an output file.
#
# Usage:
#   mistral_ocr.sh -i <input_file> [-o <output_file.md>]
#   mistral_ocr.sh --help
#
# Embedded images are saved to _resources/<inputfile>.resources/ next to the
# output file and the markdown references are rewritten to point there automatically.
#
# Required env vars:
#   MISTRAL_OCR_API_KEY   — Mistral API key
#   MISTRAL_OCR_MODEL     — model name, e.g. mistral-ocr-latest
#   MISTRAL_OCR_URL       — API base URL, e.g. https://api.mistral.ai/v1/ocr
#
# Exit codes:
#   0  success
#   1  missing env vars or dependencies
#   2  bad arguments
#   3  API error
set -euo pipefail

if [[ $# -eq 0 ]]; then
  sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'
  exit 0
fi

INPUT=""
OUTPUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i) INPUT="$2"; shift 2 ;;
    -o) OUTPUT="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'
      exit 0
      ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$INPUT" ]]; then
  echo "ERROR: -i <input> is required." >&2
  exit 2
fi

if [[ -z "$OUTPUT" ]]; then
  OUTPUT="${INPUT%.*}.md"
  if [[ -f "$OUTPUT" ]]; then
    echo "ERROR: default output file already exists: $OUTPUT (use -o to specify a different path)" >&2
    exit 2
  fi
fi

if [[ ! -f "$INPUT" ]]; then
  echo "ERROR: input file not found: $INPUT" >&2
  exit 2
fi

: "${MISTRAL_OCR_API_KEY:?ERROR: MISTRAL_OCR_API_KEY is not set}"
: "${MISTRAL_OCR_MODEL:?ERROR: MISTRAL_OCR_MODEL is not set}"
: "${MISTRAL_OCR_URL:?ERROR: MISTRAL_OCR_URL is not set}"

if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: curl is required but not found on PATH." >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not found on PATH." >&2
  exit 1
fi

# Detect MIME type for data URL construction
MIME=""
case "${INPUT##*.}" in
  pdf)  MIME="application/pdf" ;;
  png)  MIME="image/png" ;;
  jpg|jpeg) MIME="image/jpeg" ;;
  gif)  MIME="image/gif" ;;
  webp) MIME="image/webp" ;;
  tiff|tif) MIME="image/tiff" ;;
  *)
    MIME=$(file --mime-type -b "$INPUT" 2>/dev/null || echo "application/octet-stream")
    ;;
esac

# PDF → document_url, images → image_url
if [[ "$MIME" == "application/pdf" ]]; then
  DOC_TYPE="document_url"
  URL_KEY="document_url"
else
  DOC_TYPE="image_url"
  URL_KEY="image_url"
fi

TMPDIR_WORK=$(mktemp -d)
trap 'rm -rf "$TMPDIR_WORK"' EXIT

# Write data URL to a file to avoid shell ARG_MAX limits on large inputs
printf 'data:%s;base64,' "$MIME" > "$TMPDIR_WORK/data_url.txt"
base64 < "$INPUT" | tr -d '\n' >> "$TMPDIR_WORK/data_url.txt"

# Build JSON payload using --rawfile so jq never sees the large string as an arg
PAYLOAD_FILE="$TMPDIR_WORK/payload.json"
jq -n \
  --arg model  "$MISTRAL_OCR_MODEL" \
  --arg dtype  "$DOC_TYPE" \
  --arg ukey   "$URL_KEY" \
  --rawfile durl "$TMPDIR_WORK/data_url.txt" \
  '{model: $model, document: {type: $dtype, ($ukey): $durl}, include_image_base64: true}' > "$PAYLOAD_FILE"

echo "Running Mistral OCR on: $INPUT"
echo "  model: $MISTRAL_OCR_MODEL"
echo "  type:  $DOC_TYPE"
echo "  output: $OUTPUT"

RESPONSE=$(curl -fsSL \
  -X POST "${MISTRAL_OCR_URL%/}" \
  -H "Authorization: Bearer $MISTRAL_OCR_API_KEY" \
  -H "Content-Type: application/json" \
  -d "@$PAYLOAD_FILE")

# Check for API-level error in the response body
if echo "$RESPONSE" | jq -e '.error' >/dev/null 2>&1; then
  echo "ERROR: API returned an error:" >&2
  echo "$RESPONSE" | jq '.error' >&2
  exit 3
fi

# Extract markdown from all pages joined by page separators
MARKDOWN=$(echo "$RESPONSE" | jq -r '[.pages[]?.markdown // empty] | join("\n\n---\n\n")')

if [[ -z "$MARKDOWN" ]]; then
  echo "WARNING: no text extracted from response." >&2
  echo "$RESPONSE" | jq '.' >&2
fi

# Save embedded images to _resources/<inputfile>.resources/ and rewrite markdown references
INPUT_STEM="$(basename "${INPUT%.*}")"
RESOURCES_DIR="$(dirname "$OUTPUT")/_resources/${INPUT_STEM}.resources"
IMAGE_COUNT=0
while IFS=$'\t' read -r img_id img_b64; do
  [[ -z "$img_id" || -z "$img_b64" ]] && continue
  mkdir -p "$RESOURCES_DIR"
  # Strip data URL prefix if present (e.g. "data:image/jpeg;base64,")
  img_b64="${img_b64#*;base64,}"
  if printf '%s' "$img_b64" | base64 -d > "$RESOURCES_DIR/$img_id" 2>/dev/null; then
    IMAGE_COUNT=$((IMAGE_COUNT + 1))
    # Rewrite the markdown reference to point into _resources/<inputfile>.resources/
    MARKDOWN=$(printf '%s' "$MARKDOWN" | sed "s|]($img_id)|](_resources/${INPUT_STEM}.resources/$img_id)|g")
  else
    echo "WARNING: failed to save image: $img_id" >&2
  fi
done < <(echo "$RESPONSE" | jq -r '
  .pages[]?.images[]?
  | select(.image_base64 != null and .image_base64 != "")
  | "\(.id)\t\(.image_base64 | gsub("[\n\r]"; ""))"
')

# Build YAML frontmatter
FM_DATE=$(date +%Y-%m-%d)
case "${INPUT##*.}" in
  pdf)       FM_TYPE="pdf" ;;
  jpg|jpeg)  FM_TYPE="jpg" ;;
  png)       FM_TYPE="png" ;;
  *)         FM_TYPE="other" ;;
esac
{
  printf -- '---\n'
  printf 'type: %s\n'        "$FM_TYPE"
  printf 'title: "%s"\n'     "$INPUT_STEM"
  printf 'date: %s\n'        "$FM_DATE"
  printf 'source: "[[%s]]"\n' "$(basename "$INPUT")"
  printf -- '---\n\n'
  printf '%s\n' "$MARKDOWN"
} > "$OUTPUT"

if [[ "$IMAGE_COUNT" -gt 0 ]]; then
  echo "  images: $IMAGE_COUNT image(s) saved to $RESOURCES_DIR"
fi
echo "Done. Markdown written to: $OUTPUT"
