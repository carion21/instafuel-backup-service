# Instafuel Backup Service — ADR-0030
# Service autonome de backup PostgreSQL vers MinIO.
# Déployé sur Railway avec cron intégré.
#
# Image : postgres:18-alpine (pg_dump 18 inclus)
# Ajout : MinIO client (mc) + script backup.sh

FROM postgres:18-alpine

# Installer MinIO client (binaire statique officiel)
RUN apk add --no-cache curl && \
    curl -sSL https://dl.min.io/client/mc/release/linux-amd64/mc -o /usr/local/bin/mc && \
    chmod +x /usr/local/bin/mc && \
    apk del curl

COPY backup.sh /usr/local/bin/backup.sh
RUN chmod +x /usr/local/bin/backup.sh

# Utilisateur non-root (postgres déjà présent dans l'image)
USER postgres

ENTRYPOINT ["backup.sh"]
