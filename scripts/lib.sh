#!/usr/bin/env bash
# Shared helpers for deploy.sh, migrate.sh and rollback.sh. Sourced, never executed.
# The ShipTrack-* SSM documents paste this file in front of the script they run, so the scripts
# only source it when it has not already been loaded.
# shellcheck disable=SC2034  # read by the scripts that source this file
SHIPTRACK_LIB_LOADED=1

SHIPTRACK_ROOT="${SHIPTRACK_ROOT:-/opt/shiptrack}"
RELEASES_DIR="$SHIPTRACK_ROOT/releases"
CURRENT_LINK="$SHIPTRACK_ROOT/current"
HISTORY_FILE="$SHIPTRACK_ROOT/RELEASE_HISTORY"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

require_sha() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid release sha: $1"
}

# Name of the release that `current` points at (empty when nothing is deployed yet).
current_sha() {
  if [[ -L "$CURRENT_LINK" ]]; then basename "$(readlink -f "$CURRENT_LINK")"; fi
}

# fetch_release <sha> <bucket>: download, verify, and extract a release to its final path.
# The virtualenv embeds absolute paths, so a release must live at /opt/shiptrack/releases/<sha>.
fetch_release() {
  local sha=$1 bucket=$2 tmp expected actual
  require_sha "$sha"
  if [[ -f "$RELEASES_DIR/$sha/RELEASE" ]]; then
    log "release $sha is already on this host"
    return 0
  fi
  mkdir -p "$RELEASES_DIR"
  tmp=$(mktemp -d "$SHIPTRACK_ROOT/.incoming.XXXXXX")
  aws s3 cp --only-show-errors "s3://$bucket/releases/shiptrack-$sha.tar.gz" "$tmp/release.tar.gz"
  aws s3 cp --only-show-errors "s3://$bucket/releases/shiptrack-$sha.tar.gz.sha256" "$tmp/release.sha256"
  expected=$(awk '{print $1}' "$tmp/release.sha256")
  actual=$(sha256sum "$tmp/release.tar.gz" | awk '{print $1}')
  if [[ "$expected" != "$actual" ]]; then
    rm -rf "$tmp"
    die "checksum mismatch for release $sha"
  fi
  tar -xzf "$tmp/release.tar.gz" -C "$tmp"
  if [[ ! -f "$tmp/$sha/RELEASE" ]]; then
    rm -rf "$tmp"
    die "archive does not contain $sha/RELEASE"
  fi
  rm -rf "${RELEASES_DIR:?}/$sha"
  mv "$tmp/$sha" "$RELEASES_DIR/$sha"
  rm -rf "$tmp"
  log "extracted release $sha"
}

# activate_release <sha>: atomically repoint `current` (symlink to a temp name, then rename).
activate_release() {
  local sha=$1
  [[ -d "$RELEASES_DIR/$sha" ]] || die "release $sha is not on this host"
  ln -sfn "releases/$sha" "$SHIPTRACK_ROOT/current.tmp"
  mv -T "$SHIPTRACK_ROOT/current.tmp" "$CURRENT_LINK"
}

# wait_for_health: poll the local nginx until the API answers or the timeout passes.
wait_for_health() {
  local attempt
  for attempt in $(seq 1 30); do
    if curl -fsS --max-time 2 -o /dev/null http://127.0.0.1/; then
      log "service is answering"
      return 0
    fi
    sleep 1
    log "waiting for the service (attempt $attempt)"
  done
  die "service did not become healthy within 30 seconds"
}

# previous_release <current>: the release deployed before <current> (see RELEASE_HISTORY).
# Prints nothing when there is none.
previous_release() {
  local current=$1
  [[ -s "$HISTORY_FILE" ]] || return 0
  if grep -qxF -- "$current" "$HISTORY_FILE"; then
    # The newest entry before the last occurrence of <current> that differs from it.
    tac "$HISTORY_FILE" | awk -v cur="$current" \
      'seen == 0 && $0 == cur { seen = 1; next } seen == 1 && $0 != cur { print; exit }'
  else
    # <current> is not in the history (a deploy that never became healthy): use the newest entry.
    tac "$HISTORY_FILE" | awk -v cur="$current" '$0 != cur { print; exit }'
  fi
}

# prune_releases <count>: keep the newest <count> releases from the history, plus `current`.
prune_releases() {
  local count=$1 dir sha
  local -a keep=()
  if [[ -s "$HISTORY_FILE" ]]; then
    mapfile -t keep < <(tac "$HISTORY_FILE" | awk '!seen[$0]++' | head -n "$count")
  fi
  keep+=("$(current_sha)")
  for dir in "$RELEASES_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    sha=$(basename "$dir")
    if [[ " ${keep[*]} " != *" $sha "* ]]; then
      log "pruning release $sha"
      rm -rf "$dir"
    fi
  done
}
