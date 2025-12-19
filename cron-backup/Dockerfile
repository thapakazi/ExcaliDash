FROM alpine:3.18

RUN apk add --no-cache bash curl ca-certificates coreutils dcron git

WORKDIR /app

COPY backup-cron.sh /usr/local/bin/backup-cron.sh
RUN chmod +x /usr/local/bin/backup-cron.sh

ENV BACKUP_ENDPOINT=http://frontend:80/api/export/json
ENV CRON_SCHEDULE="0 2 * * *"
ENV LOGFILE=/var/log/backup-cron.log

CMD ["/usr/local/bin/backup-cron.sh"]
