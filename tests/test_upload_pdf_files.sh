#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(cd -- "$repo_root/.." && pwd)/test-run"
mkdir -p "$test_root/http-error" "$test_root/network-error" "$test_root/success"

curl() {
  printf '%s' "${FAKE_CURL_HTTP_STATUS:-200}"
  return "${FAKE_CURL_EXIT_CODE:-0}"
}

dropbox_token=synthetic-test-token
export DROPBOX_TOKEN=$dropbox_token

# Sourcing the generator must expose the upload helper without running the real pipeline.
source "$repo_root/bin/generate.sh"

printf 'synthetic pdf fixture\n' > "$test_root/http-error/report.pdf"
(
  cd "$test_root/http-error"
  export FAKE_CURL_HTTP_STATUS=401 FAKE_CURL_EXIT_CODE=0
  if upload_pdf_files; then
    echo "Expected an HTTP error to fail the upload" >&2
    exit 1
  fi
  [[ -f report.pdf ]]
)

printf 'synthetic pdf fixture\n' > "$test_root/network-error/report.pdf"
(
  cd "$test_root/network-error"
  export FAKE_CURL_HTTP_STATUS=000 FAKE_CURL_EXIT_CODE=7
  if upload_pdf_files; then
    echo "Expected a transport error to fail the upload" >&2
    exit 1
  fi
  [[ -f report.pdf ]]
)

printf 'synthetic pdf fixture\n' > "$test_root/success/report.pdf"
(
  cd "$test_root/success"
  export FAKE_CURL_HTTP_STATUS=200 FAKE_CURL_EXIT_CODE=0
  upload_pdf_files
  [[ ! -e report.pdf ]]
)

unset DROPBOX_TOKEN dropbox_token
printf 'Upload helper synthetic tests passed.\n'
