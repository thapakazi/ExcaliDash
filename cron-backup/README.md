# Cron backup service

This small container downloads the JSON export from the running frontend/backend and commits the zip to GitHub using the provided OAuth token.

Environment variables (required):

- `GITHUB_OAUTH_TOKEN` - a GitHub personal access token with `repo` scope.
- `GITHUB_REPO` - the target repo in `owner/repo` format where backups should be saved.

Optional:

- `BACKUP_ENDPOINT` - the URL to hit to get the JSON backup file (default: `http://frontend:80/api/export/json`).
- `DB_BACKUP_ENDPOINT` - the URL to hit to get the database `.db` file (default: `http://frontend:80/api/export`). This defaults to the `frontend` service inside the same Docker network.
- `BACKUP_TAG` - optional tag to include in the commit message and logs (example: `prod-us-east-1` or `backup-node-1`). Useful to identify the machine or environment that created the backup.
- `CRON_SCHEDULE` - cron schedule for backups (default: `*/5 * * * *` for testing). Change to `0 2 * * *` for daily at 02:00.

Testing locally:

1. Export the variables and run `docker compose -f docker-compose.prod.yml up --build backup-cron`.
2. Check logs: `docker logs -f excalidash-backup-cron`.
3. The script will attempt a download immediately and then on schedule; if successful it will create files under `backups/diagrams/excalidash/<YYYYMMDD>/<TIMESTAMP>.zip` and optionally `.../<TIMESTAMP>.db` in the target GitHub repo, making it easy to find and restore by date and time.

Note: The token must have permission to create content in the target repo (write access).

Implementation detail: The script uses `git` to clone the repo, add the backup file to `backups/`, commit, and push — so the token must allow pushes to the target branch.