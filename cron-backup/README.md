# Cron backup service (off-site git versioning)

This small container versions the backend's database snapshots **off-site in a
GitHub repository**. It does **not** take the snapshot itself and does **not**
call any HTTP export endpoint — the backend's native scheduled backup takes a
**consistent SQLite snapshot** (SQLite online-backup API), and this container
picks up the newest snapshot from a shared volume and commits it to git.

Instead of piling up a new file per run, it writes to a **single, stable file**
and lets **git history be the version control** — every real change is one
commit you can browse and restore.

```
backups/diagrams/excalidash/excalidash.db   # newest backend snapshot, overwritten each run
```

A commit is only recorded when the snapshot content actually changed, so
`git log` on that path is the backup history.

## How it fits together

```
  backend  ──(BACKUP_SCHEDULE)──►  writes consistent snapshots
                                    excalidash-sqlite-<ts>.db
                                            │
                                    [ shared volume: backup-snapshots ]
                                            │  (read-only)
  backup-cron ──(CRON_SCHEDULE)──►  picks newest snapshot
                                    copies → excalidash.db
                                    git commit (if changed) → GitHub  (off-site, versioned)
```

- **Backend** (native): consistent whole-DB snapshot + local retention (`BACKUP_RETENTION_DAYS`).
- **backup-cron** (this container): off-site, git-versioned history + easy restore.

The two are complementary: the backend keeps recent snapshots on disk (pruned by
retention); git keeps the long-term off-site version history.

## Environment variables

Required:

- `GITHUB_OAUTH_TOKEN` — a GitHub personal access token with `repo` scope (write access to the target repo).
- `GITHUB_REPO` — the target repo in `owner/repo` format where backups are saved.

Optional:

- `SNAPSHOT_DIR` — directory (shared volume) where the backend writes snapshots (default: `/snapshots`).
- `BACKUP_TAG` — tag included in the commit message and logs to identify the machine/environment (example: `prod-us-east-1`).
- `CRON_SCHEDULE` — how often to commit the newest snapshot (default: `*/5 * * * *`, every 5 minutes).

The backend side is configured in `docker-compose.prod.yml` via `BACKUP_SCHEDULE`,
`BACKUP_DIR=/app/backups`, and `BACKUP_RETENTION_DAYS`, with the `backup-snapshots`
volume mounted at `/app/backups` (backend, read-write) and `/snapshots` (this
container, read-only).

> Note: native scheduled backups currently support **SQLite** (`DATABASE_URL=file:...`)
> only; PostgreSQL deployments are not covered by this snapshot mechanism.

## Running

```bash
docker compose -f docker-compose.prod.yml up --build -d backend backup-cron
docker logs -f excalidash-backup-cron
```

The script commits one snapshot immediately (if present), then on the schedule.
Successful runs commit and push an updated `excalidash.db` to the target repo.

## Restoring a backup

`restore.sh` hides the git plumbing — it lists backups by date and pulls a
chosen one out to a local file, so you never have to copy a commit SHA by hand.

Run it either inside a clone of the backup repo, or from anywhere with
`GITHUB_REPO` (and `GITHUB_OAUTH_TOKEN` for private repos) set so it clones for you.

```bash
# List available backups (newest first): sha  date  message
./restore.sh list

# Restore the most recent backup to ./excalidash.db
./restore.sh restore latest

# Restore to a chosen path
./restore.sh restore latest -o ./restored.db

# Restore the backup at or just before a point in time
./restore.sh restore 20260729T120000Z
./restore.sh restore "2026-07-29 12:00"

# Restore a specific commit shown by `list`
./restore.sh restore 1a2b3c4
```

### How restore works (the flow)

```
  [ backup repo git history ]
  excalidash.db @ commit A (2026-07-29 11:55Z)   ← older
  excalidash.db @ commit B (2026-07-29 12:00Z)
  excalidash.db @ commit C (2026-07-29 12:05Z)   ← latest
              │
   ./restore.sh list          → shows A, B, C by date
              │
   ./restore.sh restore <when>
              │  1. resolve <when> → commit (latest | sha | at-or-before a timestamp)
              │  2. git show <commit>:backups/diagrams/excalidash/excalidash.db
              ▼
        ./excalidash.db   (that exact snapshot, on disk)
              │
              ▼
   Stop the backend, replace its SQLite DB (DATABASE_URL, e.g.
   /app/prisma/dev.db in the backend volume) with excalidash.db, start it.
```

You can also restore straight from the **GitHub web UI**: open
`backups/diagrams/excalidash/excalidash.db` → **History** → pick a commit by its
timestamped message → **Download raw**. No CLI needed.

## Notes

- The token must have write access to the target repo (the script clones, commits, and pushes).
- Snapshots are written owner-only (`0600`); this container runs as root, so it can read the shared volume regardless of the backend's UID.
- This container backs up **off-site to git**; it complements — and is independent of — the backend's native on-disk snapshots (see `docs/DEPLOYMENT.md`).
