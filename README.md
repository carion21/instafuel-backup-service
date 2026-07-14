# Instafuel Backup Service

Service autonome de backup PostgreSQL → MinIO.  
2 services Railway : hourly (granularité 1h) et daily (minuit, longue rétention).

**ADR :** [0030-database-backup-resilience-strategy](../docs/adr/0030-database-backup-resilience-strategy.md)

## Architecture

```
┌─────────────────────────────────────────────┐
│  Railway — backup-service-hourly            │
│  BACKUP_MODE=hourly                         │
│  RAILWAY_CRON_SCHEDULE=5 * * * *            │
│  Retention: 6h glissantes                   │
│  → minio://backups/hourly/instafuel-*.dump  │
└─────────────────────────────────────────────┘

┌─────────────────────────────────────────────┐
│  Railway — backup-service-daily             │
│  BACKUP_MODE=daily                          │
│  RAILWAY_CRON_SCHEDULE=0 0 * * *            │
│  Retention: 30 jours                        │
│  → minio://backups/daily/instafuel-*.dump   │
└─────────────────────────────────────────────┘
```

Jamais de collision : hourly à `5 * * * *`, daily à `0 0 * * *` (F1).

## Nomenclature

```
backups/
├── hourly/
│   ├── instafuel-prod-2026-07-15-01h05.dump
│   ├── instafuel-prod-2026-07-15-02h05.dump
│   ├── instafuel-prod-2026-07-15-03h05.dump
│   ├── instafuel-prod-2026-07-15-04h05.dump
│   ├── instafuel-prod-2026-07-15-05h05.dump
│   └── instafuel-prod-2026-07-15-06h05.dump  ← 6h glissantes max
│
└── daily/
    ├── instafuel-prod-2026-06-15.dump
    ├── instafuel-prod-2026-07-13.dump
    └── instafuel-prod-2026-07-14.dump          ← 30 jours max
```

## 12 garde-fous

| # | Faille | Colmatage |
|---|---|---|
| F1 | Collision minuit hourly↔daily | Cron décalés : `5 * * * *` vs `0 0 * * *` |
| F2 | Dump vide ou corrompu | Vérifie taille > 0 + magic bytes `PGDMP` |
| F3 | Upload tronqué (réseau) | `mc stat` post-upload + size check, retry 3x |
| F4 | Cleanup catastrophique | Ratio : si `deleted > kept * 2` → abort |
| F5 | Disque `/tmp` plein | `df /tmp` : si < 500 Mo → exit 1 |
| F6 | PGPASSWORD dans `/proc` | `.pgpass` 0600, `unset PGPASSWORD` |
| F7 | Pas d'alerting | Railway log exit 1 → notifs Railway |
| F8 | Backup jamais testé | Restore manuel 1x/mois (cf procédure ci-dessous) |
| F9 | MinIO inaccessible | Retry 3x backoff 30s, dump gardé dans `/tmp` |
| F10 | Pas de health check | `/tmp/last-backup.txt` avec timestamp + status |
| F11 | Dump partiel si crash | `trap cleanup EXIT` supprime le dump incomplet |
| F12 | BusyBox `head -n` bug | `mc rm --older-than` côté serveur, pas de parsing shell |

## Déploiement Railway

### Prérequis

**1. Créer utilisateur PostgreSQL read-only en prod :**
```sql
CREATE USER instafuel_backup WITH PASSWORD '<motdepasse>';
GRANT pg_read_all_data TO instafuel_backup;
```

**2. Créer access key MinIO limitée** au bucket `backups` uniquement.

### Service 1 — Hourly

| Variable | Valeur |
|---|---|
| `BACKUP_MODE` | `hourly` |
| `RAILWAY_CRON_SCHEDULE` | `5 * * * *` |
| `PGHOST` | `viaduct.proxy.rlwy.net` |
| `PGPORT` | `48229` |
| `PGDATABASE` | `railway` |
| `PGUSER` | `instafuel_backup` |
| `PGPASSWORD` | `***` |
| `NODE_ENV` | `production` |
| `MINIO_ENDPOINT` | `minio-api.beta.geasscorp.com` |
| `MINIO_ACCESS_KEY` | `***` |
| `MINIO_SECRET_KEY` | `***` |
| `MINIO_BUCKET` | `backups` |

### Service 2 — Daily

Mêmes variables, sauf :

| Variable | Valeur |
|---|---|
| `BACKUP_MODE` | `daily` |
| `RAILWAY_CRON_SCHEDULE` | `0 0 * * *` |

### Déploiement

```bash
# 1. Créer le repo et pousser
gh repo create carion21/instafuel-backup-service --public --source=. --remote=origin --push

# 2. Railway → New → Deploy from GitHub → ce repo
#    → Créer 2 services : hourly + daily (même repo, BACKUP_MODE différent)

# 3. Ajouter les variables d'environnement ci-dessus

# 4. Vérifier les logs après le premier cron
```

## Test local

```bash
cp .env.example .env
# Remplir .env avec les valeurs réelles

# Mode hourly
docker build -t instafuel-backup .
docker run --rm --env-file .env -e BACKUP_MODE=hourly instafuel-backup

# Mode daily
docker run --rm --env-file .env -e BACKUP_MODE=daily instafuel-backup
```

## Procédure de restore

```bash
# 1. Lister les backups disponibles
mc ls myminio/backups/hourly/
mc ls myminio/backups/daily/

# 2. Récupérer le dump voulu
mc cp myminio/backups/hourly/instafuel-prod-2026-07-15-06h05.dump .

# 3. Restaurer sur une base vierge
pg_restore -d instafuel_restore instafuel-prod-2026-07-15-06h05.dump

# 4. Vérifier
psql -d instafuel_restore -c "SELECT count(*) FROM transactions;"
psql -d instafuel_restore -c "SELECT count(*) FROM ledger_entries;"
```

**Test de restore à faire 1x/mois** (F8). Prendre un dump daily au hasard, restaurer sur une BDD staging.

## Garde-fous en action

Scénarios de panne et comportement attendu :

| Panne | Comportement |
|---|---|
| DB down | pg_dump exit 1 → script exit 1 → Railway log → retry au prochain cron |
| MinIO down | 3 retries → exit 1 → dump conservé `/tmp` → prochain cron réessaie |
| Dump corrompu | F2 détecte magic bytes invalides → exit 1, pas d'upload |
| `/tmp` saturé | F5 détecte < 500 Mo → exit 1 AVANT dump |
| Cleanup fou | F4 détecte ratio anormal → exit 1, rien supprimé |
| Crash mi-dump | F11 trap EXIT → dump partiel supprimé → clean |
| Horloge dérivée | F12 `--older-than` = timestamp serveur MinIO, pas local |
