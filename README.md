# Instafuel Backup Service

Service autonome de backup quotidien PostgreSQL → MinIO.  
Déployé sur Railway en tant que service séparé (indépendant du backend).

**ADR :** [0030-database-backup-resilience-strategy](../docs/adr/0030-database-backup-resilience-strategy.md)

## Architecture

```
Railway Cron (1h UTC) → backup.sh → pg_dump → mc cp → MinIO bucket backups/
                                                → mc rm --older-than 30d
```

- Image : `postgres:18-alpine` (pg_dump 18 natif)
- MinIO client : `mc` (binaire statique officiel)
- Runtime : shell, 0 dépendance externe
- Cleanup automatique > 30 jours pour l'environnement courant uniquement

## Nomenclature

```
minio://backups/database/instafuel-{env}-YYYY-MM-DD-HHhMM.dump

Exemples :
  instafuel-prod-2026-07-14-01h00.dump
  instafuel-staging-2026-07-14-01h00.dump
  instafuel-dev-2026-07-14-01h00.dump
```

Le cleanup ne touche QUE les fichiers du même environnement (`NODE_ENV`).

## Déploiement Railway

### Prérequis

1. **Utilisateur PostgreSQL read-only** — exécuter ce SQL en prod :
```sql
CREATE USER instafuel_backup WITH PASSWORD '<motdepasse>';
GRANT pg_read_all_data TO instafuel_backup;
```

2. **Policy MinIO limitée** — créer un access key avec accès bucket `backups` uniquement

### Variables d'environnement Railway

| Variable | Description | Exemple |
|---|---|---|
| `PGHOST` | Hôte PostgreSQL | `viaduct.proxy.rlwy.net` |
| `PGPORT` | Port PostgreSQL | `48229` |
| `PGDATABASE` | Base de données | `railway` |
| `PGUSER` | Utilisateur read-only | `instafuel_backup` |
| `PGPASSWORD` | Mot de passe read-only | `***` |
| `MINIO_ENDPOINT` | Hôte MinIO | `minio-api.beta.geasscorp.com` |
| `MINIO_ACCESS_KEY` | Clé MinIO (bucket backups) | `***` |
| `MINIO_SECRET_KEY` | Secret MinIO (bucket backups) | `***` |
| `MINIO_BUCKET` | Bucket MinIO | `backups` |
| `RAILWAY_CRON_SCHEDULE` | Planification cron | `0 1 * * *` (1h UTC) |
| `RETENTION_DAYS` | Rétention (optionnel) | `30` |

### Déploiement

1. Créer le repo GitHub : `carion21/instafuel-backup-service`
2. Push : `git remote add origin ... && git push -u origin main`
3. Railway → New Project → Deploy from GitHub → sélectionner le repo
4. Ajouter les variables d'environnement
5. Vérifier les logs après le premier cron

## Test local

```bash
cp .env.example .env
# Remplir .env avec les vraies valeurs

docker build -t instafuel-backup .
docker run --rm --env-file .env instafuel-backup
```

## Procédure de restore

```bash
# 1. Récupérer le dump
mc cp myminio/backups/database/instafuel-prod-2026-07-14-01h00.dump .

# 2. Restaurer sur une base vierge
pg_restore -d instafuel_restore instafuel-prod-2026-07-14-01h00.dump

# 3. Vérifier
psql -d instafuel_restore -c "SELECT count(*) FROM transactions;"
```
