#!/usr/bin/env bash
#
# restore.sh — list and restore excalidash backups produced by backup-cron.sh.
#
# The cron job overwrites a single file each run and lets git history be the
# version control:
#
#     backups/diagrams/excalidash/excalidash.db
#
# This is the backend's consistent SQLite snapshot (whole DB). Every commit that
# touches that path is one point-in-time backup. This helper hides the git
# plumbing: it lists backups by date and pulls a chosen one out to a local file,
# so you never have to copy a commit SHA by hand.
#
# Usage:
#   ./restore.sh list                    # list backups (newest first): sha  date  message
#   ./restore.sh restore <when> [opts]   # restore a backup to the current directory
#
# <when> is one of:
#   latest                 the most recent backup
#   <sha>                  a specific commit SHA (from `list`)
#   <timestamp>            e.g. 20260729T120000Z — the backup at OR JUST BEFORE this time
#   "YYYY-MM-DD HH:MM"     any git-parsable date — the backup at OR JUST BEFORE this time
#
# Options for restore:
#   -o, --output <path>    write to this path (default: ./excalidash.db)
#
# Repo selection (in priority order):
#   1. If run inside a git checkout that already contains the backup path, that repo is used.
#   2. Otherwise set GITHUB_REPO=owner/repo (and GITHUB_OAUTH_TOKEN for private repos)
#      and the repo is cloned to a temp dir automatically.
#
# Env:
#   GITHUB_REPO          owner/repo to clone when not already inside the backup repo
#   GITHUB_OAUTH_TOKEN   token for cloning a private repo
#   BACKUP_PATH          backup directory in the repo (default: backups/diagrams/excalidash)
#   BACKUP_BRANCH        branch to read history from (default: repo default branch)
#
# After restoring, put the DB back into the backend: stop the backend, replace
# the SQLite file the backend uses (DATABASE_URL, e.g. /app/prisma/dev.db in the
# backend volume) with the restored excalidash.db, then start the backend.

set -euo pipefail

BACKUP_PATH="${BACKUP_PATH:-backups/diagrams/excalidash}"
DB_REL="$BACKUP_PATH/excalidash.db"

die() { echo "error: $*" >&2; exit 1; }

# Resolve a git working directory that contains the backup history.
# Sets global REPO_DIR.
resolve_repo() {
  # 1. Are we already inside a checkout that has the backups?
  if git rev-parse --show-toplevel >/dev/null 2>&1; then
    local top
    top="$(git rev-parse --show-toplevel)"
    if [ -n "$(git -C "$top" log -1 --format=%H -- "$DB_REL" 2>/dev/null)" ]; then
      REPO_DIR="$top"
      return 0
    fi
  fi

  # 2. Clone from GITHUB_REPO.
  [ -n "${GITHUB_REPO:-}" ] || die "not inside the backup repo; set GITHUB_REPO=owner/repo (and GITHUB_OAUTH_TOKEN for private repos)"
  local url
  if [ -n "${GITHUB_OAUTH_TOKEN:-}" ]; then
    url="https://${GITHUB_OAUTH_TOKEN}@github.com/${GITHUB_REPO}.git"
  else
    url="https://github.com/${GITHUB_REPO}.git"
  fi
  REPO_DIR="$(mktemp -d "${TMPDIR:-/tmp}/excalidash-restore.XXXXXX")"
  trap 'rm -rf "$REPO_DIR"' EXIT
  echo "Cloning $GITHUB_REPO ..." >&2
  local branch_args=()
  [ -n "${BACKUP_BRANCH:-}" ] && branch_args=(--branch "$BACKUP_BRANCH")
  GIT_TERMINAL_PROMPT=0 git clone --quiet "${branch_args[@]}" "$url" "$REPO_DIR" \
    || die "clone failed for $GITHUB_REPO"
}

# Print the commit SHA for a given <when>. Echoes the SHA on stdout.
resolve_commit() {
  local when="$1"
  case "$when" in
    latest|LATEST)
      git -C "$REPO_DIR" log -1 --format=%H -- "$DB_REL"
      ;;
    *)
      # A full/short commit SHA that resolves to a real object?
      if git -C "$REPO_DIR" rev-parse --verify --quiet "${when}^{commit}" >/dev/null 2>&1; then
        git -C "$REPO_DIR" rev-parse "${when}^{commit}"
        return 0
      fi
      # 20260729T120000Z -> a date git understands, then "at or before".
      local when_norm="$when"
      if [[ "$when" =~ ^[0-9]{8}T[0-9]{6}Z$ ]]; then
        when_norm="${when:0:4}-${when:4:2}-${when:6:2} ${when:9:2}:${when:11:2}:${when:13:2} +0000"
      fi
      local sha
      sha="$(git -C "$REPO_DIR" log -1 --format=%H --before="$when_norm" -- "$DB_REL" || true)"
      [ -n "$sha" ] || die "no backup found at or before '$when'"
      echo "$sha"
      ;;
  esac
}

cmd_list() {
  resolve_repo
  echo "Backups in ${GITHUB_REPO:-current checkout} ($DB_REL), newest first:" >&2
  echo >&2
  TZ=UTC git -C "$REPO_DIR" log \
    --date=format-local:'%Y-%m-%d %H:%M:%SZ' \
    --format='%C(auto)%h%Creset  %ad  %s' \
    -- "$DB_REL" \
    | { command -v less >/dev/null 2>&1 && [ -t 1 ] && less -FRX || cat; }
}

cmd_restore() {
  local when="" out=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -o|--output) out="${2:-}"; shift 2 ;;
      -*) die "unknown option: $1" ;;
      *) [ -z "$when" ] && when="$1" || die "unexpected argument: $1"; shift ;;
    esac
  done
  [ -n "$when" ] || die "restore needs a <when> argument (try: latest, a sha, or a timestamp)"
  [ -n "$out" ] || out="excalidash.db"

  resolve_repo
  local sha
  sha="$(resolve_commit "$when")"

  git -C "$REPO_DIR" cat-file -e "$sha:$DB_REL" 2>/dev/null \
    || die "commit $sha has no '$DB_REL'"

  git -C "$REPO_DIR" show "$sha:$DB_REL" > "$out"
  local msg
  msg="$(TZ=UTC git -C "$REPO_DIR" log -1 --format='%h  %ad  %s' --date=format-local:'%Y-%m-%d %H:%M:%SZ' "$sha")"
  echo "Restored: $DB_REL @ $msg" >&2
  echo "      to: $out" >&2
  echo >&2
  echo "Next: stop the backend, replace its SQLite DB (DATABASE_URL) with $out, then start it." >&2
}

case "${1:-}" in
  list)    shift; cmd_list "$@" ;;
  restore) shift; cmd_restore "$@" ;;
  ""|-h|--help)
    sed -n '2,44p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *) die "unknown command '$1' (use: list | restore)" ;;
esac
