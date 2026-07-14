#!/bin/sh
# ============================================================
# Instafuel Backup Service — backup.sh
# ADR-0030 — Backup quotidien PostgreSQL vers MinIO
#
# Déclenché par Railway cron (0 1 * * * = 1h UTC)
# Sortie : exit 0 = succès, exit 1 = échec (Railway log l'erreur)
# ============================================================
set -e

# --- Configuration (depuis variables d'environnement Railway) ---
ENV_SUFFIX="${NODE_ENV:-dev}"
case "$ENV_SUFFIX" in
  production) ENV_SUFFIX="prod" ;;
  staging)    ENV_SUFFIX="staging" ;;
  *)          ENV_SUFFIX="dev" ;;
esac

TIMESTAMP=$(date -u +%Y-%m-%d-%Hh%M)
BACKUP_FILE="/tmp/instafuel-${ENV_SUFFIX}-${TIMESTAMP}.dump"
RETENTION_DAYS="${RETENTION_DAYS:-30}"

# Variables attendues dans l'environnement Railway :
#   PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD  (connexion PostgreSQL read-only)
#   MINIO_ENDPOINT, MINIO_ACCESS_KEY, MINIO_SECRET_KEY, MINIO_BUCKET

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] 🔄 Début backup ${ENV_SUFFIX}"

# --- 1. Configurer MinIO client ---
mc alias set backup-target \
  "https://${MINIO_ENDPOINT}" \
  "${MINIO_ACCESS_KEY}" \
  "${MINIO_SECRET_KEY}" \
  --api S3v4

# Vérifier que le bucket existe
if ! mc ls "backup-target/${MINIO_BUCKET}" >/dev/null 2>&1; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ⚠️  Bucket ${MINIO_BUCKET} introuvable — création..."
  mc mb "backup-target/${MINIO_BUCKET}"
fi

# --- 2. pg_dump ---
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] 📦 pg_dump -Fc -> ${BACKUP_FILE}"
pg_dump \
  -Fc \
  --no-owner \
  --no-acl \
  --compress=9 \
  --host="${PGHOST}" \
  --port="${PGPORT:-5432}" \
  --username="${PGUSER}" \
  --dbname="${PGDATABASE}" \
  --file="${BACKUP_FILE}"

DUMP_SIZE=$(du -h "${BACKUP_FILE}" | cut -f1)
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ✅ pg_dump terminé (${DUMP_SIZE})"

# --- 3. Upload vers MinIO ---
MINIO_PATH="backup-target/${MINIO_BUCKET}/database/instafuel-${ENV_SUFFIX}-${TIMESTAMP}.dump"
mc cp "${BACKUP_FILE}" "${MINIO_PATH}"
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] 📤 Uploadé → ${MINIO_BUCKET}/database/instafuel-${ENV_SUFFIX}-${TIMESTAMP}.dump"

# --- 4. Nettoyage rétention (> RETENTION_DAYS jours) ---
# mc rm --older-than utilise la date de dernière modification (upload)
DELETED=$(mc rm --force --older-than "${RETENTION_DAYS}d" "backup-target/${MINIO_BUCKET}/database/" 2>&1 | grep -c "Removed" || true)

# Compter les backups restants pour cet environnement
REMAINING=$(mc ls "backup-target/${MINIO_BUCKET}/database/" 2>/dev/null | grep "instafuel-${ENV_SUFFIX}-" | wc -l)

# --- 5. Nettoyer le dump local ---
rm -f "${BACKUP_FILE}"

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] 📦 [${ENV_SUFFIX}] ${REMAINING} backup(s) conservé(s), ${DELETED} supprimé(s)"
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ✅ Backup terminé"
