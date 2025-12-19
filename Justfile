# Justfile — helper tasks to manage production docker-compose (cron backup)

COMPOSE_FILE := "docker-compose.prod.yml"

# Default target

help:
	@echo "Available targets:"
	@echo "  up             - Build and start all services in detached mode"
	@echo "  up-backup      - Build and start only the backup-cron service (detached)"
	@echo "  build          - Build images defined in ${COMPOSE_FILE}"
	@echo "  logs [service] - Tail logs for all services or a specific service (e.g., logs backup-cron)"
	@echo "  logs-backup    - Tail logs for the backup-cron service"
	@echo "  stop           - Stop and remove containers for the compose file"
	@echo "  restart-backup - Restart the backup-cron service"
	@echo "  exec-backup    - Exec into the running backup-cron container (sh)"
	@echo "  env-check      - Print presence of key env vars (does not print secrets)"

up:
	docker compose -f {{COMPOSE_FILE}} up --build -d

up-backup:
	docker compose -f {{COMPOSE_FILE}} up --build backup-cron -d

build:
	docker compose -f {{COMPOSE_FILE}} build

logs service="":
	@bash -lc 'if [ -z "{{service}}" ]; then docker compose -f {{COMPOSE_FILE}} logs -f; else docker compose -f {{COMPOSE_FILE}} logs -f {{service}}; fi'

ps:
	docker compose -f {{COMPOSE_FILE}} ps

get-backup-logs:
	docker compose -f {{COMPOSE_FILE}} exec  backup-cron tail -f /var/log/backup-cron.log

stop:
	docker compose -f {{COMPOSE_FILE}} down

restart-backup:
	docker compose -f {{COMPOSE_FILE}} restart backup-cron

exec-backup:
	docker compose -f {{COMPOSE_FILE}} exec backup-cron sh

env-check:
	@echo "GITHUB_REPO=${GITHUB_REPO:-unset}"
	@echo "GITHUB_OAUTH_TOKEN=${GITHUB_OAUTH_TOKEN:+set}"
	@echo "BACKUP_TAG=${BACKUP_TAG:-unset}"
	@echo "CRON_SCHEDULE=${CRON_SCHEDULE:-unset}"
