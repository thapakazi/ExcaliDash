#!/bin/sh
set -eu

# Required env vars
: "${GITHUB_OAUTH_TOKEN:?Need GITHUB_OAUTH_TOKEN}"
: "${GITHUB_REPO:?Need GITHUB_REPO (owner/repo)}"

# Directory (a shared, read-only volume) where the backend's native scheduled
# backup writes consistent SQLite snapshots named `excalidash-sqlite-<ts>.db`.
# This container does NOT take the snapshot itself — the backend's SQLite
# online-backup API does (enabled via BACKUP_SCHEDULE/BACKUP_DIR on the backend).
# We just pick up the newest snapshot and version it off-site in git.
SNAPSHOT_DIR="${SNAPSHOT_DIR:-/snapshots}"
CRON_SCHEDULE="${CRON_SCHEDULE:-*/5 * * * *}"
LOGFILE="${LOGFILE:-/var/log/backup-cron.log}"

# Ensure log directory exists
mkdir -p "$(dirname "$LOGFILE")" || true
: "${LOGFILE}" >/dev/null 2>&1 || touch "$LOGFILE" || true

# Optional tag to identify the machine or instance running this job
# Example: "prod-us-east-1" or "my-laptop"
BACKUP_TAG="${BACKUP_TAG:-}"
# Sanitize tag for use in commit messages (replace unsafe chars with '-')
BACKUP_TAG_SAFE="$(printf '%s' "$BACKUP_TAG" | tr -d '\n' | sed 's/[^[:alnum:]._-]/-/g')"

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1" >> "$LOGFILE"
}

backup() {
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"

  # Pick the newest snapshot the backend has written to the shared volume.
  latest_snapshot="$(ls -1t "$SNAPSHOT_DIR"/excalidash-sqlite-*.db 2>/dev/null | head -n 1 || true)"
  if [ -z "$latest_snapshot" ]; then
    log "No snapshot found in $SNAPSHOT_DIR — is the backend's BACKUP_SCHEDULE enabled and the volume shared? Skipping."
    return 1
  fi
  log "Latest snapshot: $latest_snapshot"

  repo_tmp="/tmp/repo-$timestamp"
  GIT_URL="https://$GITHUB_OAUTH_TOKEN@github.com/$GITHUB_REPO.git"
  export GIT_TERMINAL_PROMPT=0
  rm -rf "$repo_tmp"

  if ! git clone --depth 1 "$GIT_URL" "$repo_tmp" >/dev/null 2>&1; then
    log "Git clone FAILED for $GITHUB_REPO"
    return 4
  fi

  git -C "$repo_tmp" config user.email "backup-bot@localhost"
  git -C "$repo_tmp" config user.name "backup-bot"

  # Single, stable file: git history is the version control. Each run overwrites
  # it; git only records a commit when the snapshot content changed (see the
  # diff --cached check below). Restore any point with cron-backup/restore.sh.
  backup_dir="backups/diagrams/excalidash"
  dest="$repo_tmp/$backup_dir"
  mkdir -p "$dest"
  cp "$latest_snapshot" "$dest/excalidash.db"
  git -C "$repo_tmp" add "$backup_dir/excalidash.db"

  # Only commit if the snapshot differs from the last backup.
  if git -C "$repo_tmp" diff --cached --quiet; then
    log "No changes to commit (snapshot identical to last backup)"
    rm -rf "$repo_tmp"
    return 0
  fi

  commit_msg="Automated backup $timestamp"
  if [ -n "$BACKUP_TAG_SAFE" ]; then
    commit_msg="$commit_msg [tag: $BACKUP_TAG_SAFE]"
  fi

  if ! git -C "$repo_tmp" commit -m "$commit_msg" >/dev/null 2>&1; then
    log "Commit failed"
    rm -rf "$repo_tmp"
    return 2
  fi

  if git -C "$repo_tmp" push "$GIT_URL" HEAD >/tmp/git_push_output 2>&1; then
    log "Committed and pushed backup for $timestamp to $GITHUB_REPO (tag: $BACKUP_TAG_SAFE)"
    rm -rf "$repo_tmp"
    return 0
  else
    log "Git push FAILED, output: $(cat /tmp/git_push_output)"
    rm -rf "$repo_tmp"
    return 3
  fi
}

# write cron to /etc/crontabs/root (Alpine crond)
echo "$CRON_SCHEDULE /usr/local/bin/backup-cron.sh run >> $LOGFILE 2>&1" > /etc/crontabs/root

case "${1:-}" in
  run)
    backup
    ;;
  *)
    # Run once immediately then start crond in foreground
    backup || true
    crond -f -l 8
    ;;
esac
