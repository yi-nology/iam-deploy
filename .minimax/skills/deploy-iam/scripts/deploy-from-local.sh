#!/usr/bin/env bash
# Build IAM in GitHub Actions, then transfer the resulting images through this machine.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_DIR="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)"
OVERLAY_FILE="${SKILL_DIR}/assets/docker-compose.local-images.yml"

GITHUB_REPO="yi-nology/iam-deploy"
WORKFLOW_FILE="build-iam.yml"
WORKFLOW_REF="main"
SERVER_REF="main"
WEB_REF="main"
RELEASE_TAG=""
REMOTE_HOST="10.44.129.215"
REMOTE_USER="root"
REMOTE_DIR="/opt/iam"
SSH_PORT="22"
SSH_KEY="${SSH_KEY_PATH:-}"
KEEP_ARCHIVE=false

usage() {
  cat <<'USAGE'
Usage: deploy-from-local.sh [options]

Build IAM images through GitHub Actions, pull them to this machine, and upload them
to the 215 environment. GHCR_TOKEN must grant read access to the IAM packages.

Options:
  --server-ref REF       iam-server branch or tag (default: main)
  --web-ref REF          iam-web branch or tag (default: main)
  --tag TAG              immutable release tag; generated when omitted
  --repo OWNER/REPO      GitHub repository (default: yi-nology/iam-deploy)
  --workflow-ref REF     iam-deploy ref containing the workflow (default: main)
  --host HOST            215 SSH host (default: 10.44.129.215)
  --user USER            215 SSH user (default: root)
  --remote-dir PATH      deployment directory on 215 (default: /opt/iam)
  --ssh-port PORT        SSH port (default: 22)
  --ssh-key PATH         SSH private key; otherwise use the SSH agent
  --keep-archive         retain the local image archive after success
  -h, --help             show this help
USAGE
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command is unavailable: $1"
}

validate_tag() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || die "invalid Docker tag: $1"
  [[ "$1" != "main" && "$1" != "latest" ]] || die "refuse mutable release tag: $1"
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-ref) SERVER_REF="$2"; shift 2 ;;
    --web-ref) WEB_REF="$2"; shift 2 ;;
    --tag) RELEASE_TAG="$2"; shift 2 ;;
    --repo) GITHUB_REPO="$2"; shift 2 ;;
    --workflow-ref) WORKFLOW_REF="$2"; shift 2 ;;
    --host) REMOTE_HOST="$2"; shift 2 ;;
    --user) REMOTE_USER="$2"; shift 2 ;;
    --remote-dir) REMOTE_DIR="$2"; shift 2 ;;
    --ssh-port) SSH_PORT="$2"; shift 2 ;;
    --ssh-key) SSH_KEY="$2"; shift 2 ;;
    --keep-archive) KEEP_ARCHIVE=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

for value in "$SERVER_REF" "$WEB_REF" "$WORKFLOW_REF" "$REMOTE_HOST" "$REMOTE_USER" "$REMOTE_DIR"; do
  [[ -n "$value" ]] || die "empty option value is not allowed"
done
[[ "$SSH_PORT" =~ ^[0-9]{1,5}$ ]] || die "invalid SSH port: $SSH_PORT"
[[ -f "$OVERLAY_FILE" ]] || die "missing Compose overlay: $OVERLAY_FILE"
if [[ -n "$SSH_KEY" ]]; then
  [[ -f "$SSH_KEY" ]] || die "SSH key does not exist: $SSH_KEY"
fi

if [[ -z "$RELEASE_TAG" ]]; then
  local_sha="$(git -C "$REPO_DIR" rev-parse --short=8 HEAD 2>/dev/null || printf 'local')"
  RELEASE_TAG="iam-$(date -u +%Y%m%d%H%M%S)-${local_sha}"
fi
validate_tag "$RELEASE_TAG"

require_command gh
require_command docker
require_command ssh
require_command scp
if ! command -v shasum >/dev/null 2>&1 && ! command -v sha256sum >/dev/null 2>&1; then
  die "required SHA-256 command is unavailable: shasum or sha256sum"
fi
[[ -n "${GHCR_TOKEN:-}" ]] || die "GHCR_TOKEN must be set with read:packages access"

gh auth status --hostname github.com >/dev/null
GHCR_USERNAME="${GHCR_USERNAME:-$(gh api user --jq .login)}"

printf 'Dispatching %s with release tag %s\n' "$WORKFLOW_FILE" "$RELEASE_TAG"
gh workflow run "$WORKFLOW_FILE" \
  --repo "$GITHUB_REPO" \
  --ref "$WORKFLOW_REF" \
  -f "iam_server_ref=${SERVER_REF}" \
  -f "iam_web_ref=${WEB_REF}" \
  -f 'push_images=true' \
  -f "release_tag=${RELEASE_TAG}"

run_id=""
deadline=$((SECONDS + 120))
while [[ -z "$run_id" && $SECONDS -lt $deadline ]]; do
  run_id="$(gh run list \
    --repo "$GITHUB_REPO" \
    --workflow "$WORKFLOW_FILE" \
    --event workflow_dispatch \
    --limit 50 \
    --json databaseId,displayTitle \
    --jq ".[] | select(.displayTitle == \"Build IAM (${RELEASE_TAG})\") | .databaseId" \
    | head -n 1)"
  [[ -n "$run_id" ]] || sleep 2
done
[[ -n "$run_id" ]] || die "could not find the dispatched GitHub Actions run for ${RELEASE_TAG}"

printf 'Waiting for GitHub Actions run %s\n' "$run_id"
gh run watch "$run_id" --repo "$GITHUB_REPO" --exit-status || die "GitHub Actions build failed"

server_image="ghcr.io/yi-nology/iam-server:${RELEASE_TAG}"
web_image="ghcr.io/yi-nology/iam-web:${RELEASE_TAG}"

printf '%s' "$GHCR_TOKEN" | docker login ghcr.io --username "$GHCR_USERNAME" --password-stdin >/dev/null
docker pull --platform linux/amd64 "$server_image"
docker pull --platform linux/amd64 "$web_image"

for image in "$server_image" "$web_image"; do
  platform="$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$image")"
  [[ "$platform" == 'linux/amd64' ]] || die "unexpected image platform for ${image}: ${platform}"
done

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/iam-deploy.XXXXXX")"
archive="${work_dir}/iam-${RELEASE_TAG}.tar"
checksum_file="${archive}.sha256"
cleanup() {
  if [[ "$KEEP_ARCHIVE" == true ]]; then
    printf 'Local archive retained at %s\n' "$work_dir"
  else
    rm -rf "$work_dir"
  fi
}
trap cleanup EXIT

docker save --output "$archive" "$server_image" "$web_image"
printf '%s  %s\n' "$(sha256_file "$archive")" "$(basename "$archive")" > "$checksum_file"

ssh_args=(-p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=yes)
scp_args=(-P "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=yes)
if [[ -n "$SSH_KEY" ]]; then
  ssh_args+=(-i "$SSH_KEY")
  scp_args+=(-i "$SSH_KEY")
fi
target="${REMOTE_USER}@${REMOTE_HOST}"
remote_tmp="/tmp/iam-deploy-${RELEASE_TAG}"

ssh "${ssh_args[@]}" "$target" "mkdir -p -- '${remote_tmp}'"
scp "${scp_args[@]}" "$archive" "$checksum_file" "$OVERLAY_FILE" "${target}:${remote_tmp}/"

ssh "${ssh_args[@]}" "$target" bash -s -- \
  "$REMOTE_DIR" "$remote_tmp" "$RELEASE_TAG" "$server_image" "$web_image" <<'REMOTE_SCRIPT'
set -Eeuo pipefail

remote_dir="$1"
remote_tmp="$2"
release_tag="$3"
server_image="$4"
web_image="$5"
archive="${remote_tmp}/iam-${release_tag}.tar"
checksum_file="${archive}.sha256"
overlay_source="${remote_tmp}/docker-compose.local-images.yml"
overlay_file="${remote_dir}/.iam-deploy-images.yml"
images_env="${remote_dir}/.iam-images.env"
history_dir="${remote_dir}/.deploy-history"
timestamp="$(date -u +%Y%m%d-%H%M%S)"

fail() {
  printf 'REMOTE ERROR: %s\n' "$*" >&2
  exit 1
}

[[ -f "${remote_dir}/docker-compose.yml" ]] || fail "missing ${remote_dir}/docker-compose.yml"
[[ -f "${remote_dir}/.env" ]] || fail "missing ${remote_dir}/.env"
[[ -f "$archive" && -f "$checksum_file" && -f "$overlay_source" ]] || fail "uploaded deployment files are incomplete"

cd "$remote_tmp"
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum -c "$(basename "$checksum_file")"
else
  shasum -a 256 -c "$(basename "$checksum_file")"
fi

docker load --input "$archive"
docker image inspect "$server_image" >/dev/null
docker image inspect "$web_image" >/dev/null

previous_server_container="$(docker compose -f "${remote_dir}/docker-compose.yml" ps -q iam-server | head -n 1)"
previous_web_container="$(docker compose -f "${remote_dir}/docker-compose.yml" ps -q iam-web | head -n 1)"
previous_server_image="$(docker inspect --format '{{.Config.Image}}' "$previous_server_container" 2>/dev/null || true)"
previous_web_image="$(docker inspect --format '{{.Config.Image}}' "$previous_web_container" 2>/dev/null || true)"
[[ -n "$previous_server_image" && -n "$previous_web_image" ]] || fail "existing IAM containers are required for a safe rollback"

mkdir -p "$history_dir"
[[ -f "$images_env" ]] && cp "$images_env" "${history_dir}/${timestamp}.iam-images.env.pre"
[[ -f "$overlay_file" ]] && cp "$overlay_file" "${history_dir}/${timestamp}.overlay.pre"
cp "$overlay_source" "$overlay_file"
printf 'IAM_SERVER_IMAGE=%s\nIAM_WEB_IMAGE=%s\n' "$server_image" "$web_image" > "$images_env"

compose() {
  docker compose \
    --env-file "${remote_dir}/.env" \
    --env-file "$images_env" \
    -f "${remote_dir}/docker-compose.yml" \
    -f "$overlay_file" \
    "$@"
}

healthy() {
  local server_id status binding web_port
  server_id="$(compose ps -q iam-server)"
  [[ -n "$server_id" ]] || return 1
  status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$server_id")"
  [[ "$status" == healthy ]] || return 1
  curl -fsS --max-time 5 http://127.0.0.1:8000/health >/dev/null || return 1
  binding="$(compose port iam-web 80 | head -n 1)"
  [[ -n "$binding" ]] || return 1
  web_port="${binding##*:}"
  curl -fsS --max-time 5 "http://127.0.0.1:${web_port}/" | head -c 500 | grep -qi '<html'
}

rollback() {
  printf 'Rolling back to %s and %s\n' "$previous_server_image" "$previous_web_image" >&2
  printf 'IAM_SERVER_IMAGE=%s\nIAM_WEB_IMAGE=%s\n' "$previous_server_image" "$previous_web_image" > "$images_env"
  compose up -d --no-build --pull never iam-server iam-web
}

deployment_ok=false
if compose up -d --no-build --pull never iam-server iam-web; then
  for _ in {1..12}; do
    if healthy; then
      deployment_ok=true
      break
    fi
    sleep 5
  done
fi

if [[ "$deployment_ok" != true ]]; then
  if rollback; then
    for _ in {1..12}; do
      if healthy; then
        break
      fi
      sleep 5
    done
  fi
  if healthy; then
    printf '%s %s FAIL_ROLLED_BACK\n' "$timestamp" "$release_tag" >> "${history_dir}/history.log"
    exit 3
  fi
  printf '%s %s FAIL_ROLLBACK_FAILED\n' "$timestamp" "$release_tag" >> "${history_dir}/history.log"
  exit 4
fi

printf '%s %s OK\n' "$timestamp" "$release_tag" >> "${history_dir}/history.log"
rm -rf "$remote_tmp"
printf 'Deployment complete: %s\n' "$release_tag"
REMOTE_SCRIPT
