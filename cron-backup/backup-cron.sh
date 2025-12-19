#!/bin/sh
set -eu

# Required env vars
: "${GITHUB_OAUTH_TOKEN:?Need GITHUB_OAUTH_TOKEN}"
: "${GITHUB_REPO:?Need GITHUB_REPO (owner/repo)}"
BACKUP_ENDPOINT="${BACKUP_ENDPOINT:-http://frontend:80/api/export/json}"
# DB export endpoint (defaults to the frontend service)
DB_BACKUP_ENDPOINT="${DB_BACKUP_ENDPOINT:-http://frontend:80/api/export}"
CRON_SCHEDULE="${CRON_SCHEDULE:-*/5 * * * *}"
LOGFILE="${LOGFILE:-/var/log/backup-cron.log}"

# Ensure log directory exists
mkdir -p "$(dirname "$LOGFILE")" || true
: "${LOGFILE}" >/dev/null 2>&1 || touch "$LOGFILE" || true

backup() {
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  tmp="/tmp/backup-$timestamp.zip"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Starting backup from $BACKUP_ENDPOINT" >> "$LOGFILE"

  if curl -fsSL "$BACKUP_ENDPOINT" -o "$tmp"; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Downloaded JSON backup to $tmp" >> "$LOGFILE"

    # Attempt DB backup as well (best-effort)
    tmp_db=""
    if [ -n "$DB_BACKUP_ENDPOINT" ]; then
      tmp_db="/tmp/backup-db-$timestamp.db"
      if curl -fsSL "$DB_BACKUP_ENDPOINT" -o "$tmp_db"; then
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Downloaded DB backup to $tmp_db" >> "$LOGFILE"
      else
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] DB download FAILED from $DB_BACKUP_ENDPOINT" >> "$LOGFILE"
        tmp_db=""
      fi
    fi

    # Use git to commit the backup files to the repository
    repo_tmp="/tmp/repo-$timestamp"
    GIT_URL="https://$GITHUB_OAUTH_TOKEN@github.com/$GITHUB_REPO.git"

    export GIT_TERMINAL_PROMPT=0
    rm -rf "$repo_tmp"

    if git clone --depth 1 "$GIT_URL" "$repo_tmp" >/dev/null 2>&1; then
      git -C "$repo_tmp" config user.email "backup-bot@localhost"
      git -C "$repo_tmp" config user.name "backup-bot"

      # Use a date-based directory structure for easier lookup and restore
      date_dir="$(date -u +%Y%m%d)"
      time_stamp="$timestamp"
      dest="$repo_tmp/backups/diagrams/excalidash/$date_dir"
      mkdir -p "$dest"
      cp "$tmp" "$dest/$time_stamp.zip"
      if [ -n "$tmp_db" ]; then
        cp "$tmp_db" "$dest/$time_stamp.db"
      fi
      git -C "$repo_tmp" add "backups/diagrams/excalidash/$date_dir/$time_stamp.zip"
      if [ -n "$tmp_db" ]; then
        git -C "$repo_tmp" add "backups/diagrams/excalidash/$date_dir/$time_stamp.db"
      fi

      # Only commit if there are staged changes
      if git -C "$repo_tmp" diff --cached --quiet; then
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] No changes to commit" >> "$LOGFILE"
        rm -rf "$repo_tmp"
        rm -f "$tmp" "$tmp_db"
        return 0
      fi

      if git -C "$repo_tmp" commit -m "Automated backup $timestamp" >/dev/null 2>&1; then
        if git -C "$repo_tmp" push "$GIT_URL" HEAD >/tmp/git_push_output 2>&1; then
          echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Committed and pushed backups for $timestamp to $GITHUB_REPO" >> "$LOGFILE"
          rm -rf "$repo_tmp" "$tmp" "$tmp_db"
          return 0
        else
          echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Git push FAILED, output: $(cat /tmp/git_push_output)" >> "$LOGFILE"
          rm -rf "$repo_tmp"
          rm -f "$tmp" "$tmp_db"
          return 3
        fi
      else
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Commit failed" >> "$LOGFILE"
        rm -rf "$repo_tmp"
        rm -f "$tmp" "$tmp_db"
        return 2
      fi
    else
      echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Git clone FAILED for $GIT_URL" >> "$LOGFILE"
      rm -f "$tmp" "$tmp_db"
      return 4
    fi
  else
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Download FAILED from $BACKUP_ENDPOINT" >> "$LOGFILE"
    return 1
  fi
}

# write cron to /etc/crontabs/root (Alpine crond)
# CRON_SCHEDULE defaults to every 5 minutes for easier testing
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
