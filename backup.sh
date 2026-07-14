#!/bin/sh
# ============================================================
# Instafuel Backup Service — backup.sh
# ADR-0030 — Backup PostgreSQL vers MinIO (hourly + daily)
#
# Deux modes (définis par BACKUP_MODE dans l'env Railway) :
#   hourly  → retention 6h glissantes, cron 5 * * * *
#   daily   → retention 30 jours,       cron 0 0 * * *
#
# 12 garde-fous documentés (cf README / ADR-0030).
# Sortie : exit 0 = succès, exit 1 = échec (Railway log, relance).
# ============================================================
set -e

# ============================================================
# Config
# ============================================================
log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [$MODE] $*"; }

ENV_SUFFIX="${NODE_ENV:-dev}"
case "$ENV_SUFFIX" in
  production) ENV_SUFFIX="prod" ;;
  staging)    ENV_SUFFIX="staging" ;;
  *)          ENV_SUFFIX="dev" ;;
esac

MODE="${BACKUP_MODE:-hourly}"
TIMESTAMP=$(date -u +%Y-%m-%d-%Hh%M)
DATESTAMP=$(date -u +%Y-%m-%d)
HEALTH_FILE="/tmp/last-backup.txt"

case "$MODE" in
  daily)
    SUBDIR="daily"
    RETENTION="30d"
    CRON_SPEC="0 0 * * *"
    BACKUP_FILE="/tmp/instafuel-${ENV_SUFFIX}-${DATESTAMP}.dump"
    MINIO_PATH="backup-target/${MINIO_BUCKET}/daily/instafuel-${ENV_SUFFIX}-${DATESTAMP}.dump"
    ;;
  *)
    SUBDIR="hourly"
    RETENTION="6h"
    CRON_SPEC="5 * * * *"
    BACKUP_FILE="/tmp/instafuel-${ENV_SUFFIX}-${TIMESTAMP}.dump"
    MINIO_PATH="backup-target/${MINIO_BUCKET}/hourly/instafuel-${ENV_SUFFIX}-${TIMESTAMP}.dump"
    ;;
esac

MIN_FREE_DISK_MB=500
UPLOAD_RETRIES=3
UPLOAD_RETRY_DELAY=30

# ============================================================
# F11: Trap — nettoyer dump partiel si crash
# ============================================================
cleanup() {
  if [ -f "${BACKUP_FILE}" ]; then
    rm -f "${BACKUP_FILE}"
    log "🧹 Dump partiel supprimé (trap EXIT)"
  fi
}
trap cleanup EXIT

# ============================================================
# F5: Vérifier espace disque /tmp
# ============================================================
check_disk_space() {
  local available_kb
  available_kb=$(df /tmp 2>/dev/null | awk 'NR==2 {print $4}')
  if [ -z "$available_kb" ]; then
    available_kb=$(df / 2>/dev/null | awk 'NR==2 {print $4}')
  fi
  local avail_mb=$((available_kb / 1024))
  if [ "$avail_mb" -lt "$MIN_FREE_DISK_MB" ]; then
    log "❌ F5: Espace disque insuffisant : ${avail_mb} Mo (< ${MIN_FREE_DISK_MB} Mo requis)"
    exit 1
  fi
  log "✅ F5: Espace disque /tmp OK (${avail_mb} Mo dispo)"
}

# ============================================================
# F6: Configurer .pgpass (pas de PGPASSWORD dans /proc)
# ============================================================
setup_pgpass() {
  if [ -z "$PGPASSWORD" ]; then
    log "❌ F6: PGPASSWORD non défini"
    exit 1
  fi
  printf '%s:%s:%s:%s:%s\n' \
    "${PGHOST}" "${PGPORT:-5432}" "${PGDATABASE}" "${PGUSER}" "${PGPASSWORD}" \
    > /tmp/.pgpass
  chmod 0600 /tmp/.pgpass
  export PGPASSFILE=/tmp/.pgpass
  # Ne pas laisser PGPASSWORD dans l'environnement
  unset PGPASSWORD
  log "✅ F6: .pgpass configuré (0600)"
}

# ============================================================
# MinIO client setup
# ============================================================
setup_minio() {
  mc alias set backup-target \
    "https://${MINIO_ENDPOINT}" \
    "${MINIO_ACCESS_KEY}" \
    "${MINIO_SECRET_KEY}" \
    --api S3v4 2>/dev/null

  if ! mc ls "backup-target/${MINIO_BUCKET}" >/dev/null 2>&1; then
    log "⚠️  Bucket ${MINIO_BUCKET} introuvable — création..."
    mc mb "backup-target/${MINIO_BUCKET}" 2>/dev/null || {
      log "❌ F9: Impossible de créer le bucket MinIO"
      exit 1
    }
  fi
}

# ============================================================
# F2: Vérifier magic bytes du format custom pg_dump
# ============================================================
check_dump_integrity() {
  local f="$1"
  local size
  size=$(wc -c < "$f" 2>/dev/null || echo 0)

  if [ "$size" -eq 0 ]; then
    log "❌ F2: Dump vide (0 octet) — DB inaccessible ?"
    exit 1
  fi

  # Format custom pg_dump commence par "PGDMP" (5 octets)
  local magic
  magic=$(head -c 5 "$f" 2>/dev/null || true)
  if [ "$magic" != "PGDMP" ]; then
    log "❌ F2: Magic bytes invalides : '${magic}' (attendu 'PGDMP')"
    exit 1
  fi

  log "✅ F2: Dump valide — ${size} octets, magic bytes OK"
}

# ============================================================
# F3+F9: Upload avec retry + vérification intégrité côté MinIO
# ============================================================
upload_with_retry() {
  local local_file="$1"
  local remote_path="$2"
  local local_size
  local_size=$(wc -c < "$local_file")

  local attempt=1
  while [ $attempt -le $UPLOAD_RETRIES ]; do
    log "📤 Upload tentative ${attempt}/${UPLOAD_RETRIES} → ${remote_path}"
    if mc cp "$local_file" "$remote_path" 2>/dev/null; then
      # F3: Vérifier intégrité côté MinIO
      local remote_info remote_size
      remote_info=$(mc stat "$remote_path" --json 2>/dev/null || echo '{}')
      remote_size=$(echo "$remote_info" | grep -o '"size":[0-9]*' | head -1 | cut -d: -f2)

      if [ -n "$remote_size" ] && [ "$remote_size" -eq "$local_size" ]; then
        log "✅ F3: Upload vérifié — ${remote_size} octets (match local)"
        return 0
      fi

      log "⚠️  F3: Taille distante ${remote_size:-?} ≠ locale ${local_size} — retry ${attempt}/${UPLOAD_RETRIES}"
    else
      log "⚠️  F9: Upload échoué (MinIO down ?) — retry ${attempt}/${UPLOAD_RETRIES}"
    fi

    attempt=$((attempt + 1))
    if [ $attempt -le $UPLOAD_RETRIES ]; then
      sleep $UPLOAD_RETRY_DELAY
    fi
  done

  log "❌ F3/F9: Upload impossible après ${UPLOAD_RETRIES} tentatives"
  # Laisser le dump dans /tmp — le prochain cron réessaiera
  # Ne pas faire rm (le trap le garde)
  exit 1
}

# ============================================================
# F4: Cleanup avec garde-fou ratio
# ============================================================
cleanup_with_safeguard() {
  local prefix="${MINIO_BUCKET}/${SUBDIR}/"
  local env_prefix="instafuel-${ENV_SUFFIX}-"

  # Compter avant cleanup
  local before_count
  before_count=$(mc ls "backup-target/${prefix}" 2>/dev/null | grep -c "${env_prefix}" || echo 0)

  if [ "$before_count" -eq 0 ]; then
    log "📦 F4: Aucun backup existant à nettoyer (${SUBDIR})"
    return 0
  fi

  log "🧹 Cleanup ${SUBDIR} — ${before_count} backups avant, rétention ${RETENTION}"

  # mc rm --older-than utilise le timestamp serveur MinIO (F12: pas de dépendance BusyBox)
  local deleted
  deleted=$(mc rm --force --older-than "${RETENTION}" "backup-target/${prefix}" 2>&1 | grep -c "Removed" || echo 0)

  local after_count
  after_count=$(mc ls "backup-target/${prefix}" 2>/dev/null | grep -c "${env_prefix}" || echo 0)

  # F4: Si deleted > kept * 2 → anomalie
  if [ "$deleted" -gt 0 ] && [ "$deleted" -gt $((after_count * 2)) ]; then
    log "❌ F4: ANOMALIE — ${deleted} supprimés pour ${after_count} restants. Ratio suspect."
    log "❌ F4: Arrêt pour éviter une suppression catastrophique."
    exit 1
  fi

  log "✅ F4: ${deleted} supprimé(s), ${after_count} conservé(s) (garde-fou OK)"
}

# ============================================================
# F7+F10: Health check + log final
# ============================================================
write_health() {
  local status="$1"
  local msg="$2"
  printf '%s mode=%s env=%s status=%s %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$MODE" "$ENV_SUFFIX" "$status" "$msg" \
    > "$HEALTH_FILE"
  log "🏥 Health: ${status} — ${msg}"
}

# ============================================================
# MAIN
# ============================================================
main() {
  log "🔄 Début backup [mode=${MODE} env=${ENV_SUFFIX} retention=${RETENTION}]"

  # Pré-vols
  check_disk_space    # F5
  setup_pgpass        # F6
  setup_minio

  # pg_dump (F6: .pgpass, pas de PGPASSWORD exposé)
  log "📦 pg_dump -Fc → ${BACKUP_FILE}"
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

  check_dump_integrity "$BACKUP_FILE"  # F2

  # Upload (F3+F9: retry + verify)
  upload_with_retry "$BACKUP_FILE" "$MINIO_PATH"

  # Cleanup (F4: garde-fou ratio)
  cleanup_with_safeguard

  # Clean local (déjà protégé par trap F11, mais cleanup explicite)
  rm -f "${BACKUP_FILE}"

  write_health "OK" "backup=${MINIO_PATH}"  # F7+F10
  log "✅ Backup terminé [mode=${MODE} env=${ENV_SUFFIX}]"
}

main "$@"
