FROM alpine:3.18

RUN apk add --no-cache bash curl ca-certificates coreutils dcron git

WORKDIR /app

COPY backup-cron.sh /usr/local/bin/backup-cron.sh
COPY restore.sh /usr/local/bin/restore.sh
RUN chmod +x /usr/local/bin/backup-cron.sh /usr/local/bin/restore.sh

# Directory where the backend's native scheduler writes SQLite snapshots,
# shared into this container as a read-only volume (see docker-compose.prod.yml).
ENV SNAPSHOT_DIR=/snapshots
ENV CRON_SCHEDULE="*/5 * * * *"
ENV LOGFILE=/var/log/backup-cron.log

CMD ["/usr/local/bin/backup-cron.sh"]
