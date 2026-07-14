# Instafuel Backup Service

Service autonome de backup PostgreSQL → MinIO.  
2 services Railway : **hourly** (1h de granularité) et **daily** (minuit, longue rétention).

**ADR :** [0030-database-backup-resilience-strategy](https://github.com/carion21/instafuel-workspace/blob/main/docs/adr/0030-database-backup-resilience-strategy.md)

---

## Pourquoi ce service existe

Avant ce service, la base de données de production Instafuel tournait **sans aucune sauvegarde automatisée**.

| Risque | Impact sans backup |
|---|---|
| `DELETE FROM transactions` accidentel | Perte définitive de toutes les transactions |
| Migration Prisma qui corrompt une table | Données irrécupérables |
| Compromission du compte Railway | Perte totale de la BDD et de tout l'historique |
| Corruption disque Railway | Perte totale |

Ce service élimine ces risques avec **deux flux de backup indépendants** (hourly + daily) qui ne partagent aucun point de défaillance commun.

---

## Comment ça marche

```
┌──────────────────────────────────────────────────────────┐
│                     Railway (2 services)                  │
│                                                          │
│  ┌─────────────────────────┐  ┌─────────────────────────┐│
│  │ backup-service-hourly   │  │ backup-service-daily    ││
│  │                         │  │                         ││
│  │ BACKUP_MODE=hourly      │  │ BACKUP_MODE=daily       ││
│  │ Cron: 5 * * * *         │  │ Cron: 0 0 * * *         ││
│  │ Retention: 6h           │  │ Retention: 30 jours     ││
│  │                         │  │                         ││
│  │ pg_dump → mc cp →       │  │ pg_dump → mc cp →       ││
│  │   backups/hourly/       │  │   backups/daily/        ││
│  └──────────┬──────────────┘  └──────────┬──────────────┘│
│             │                            │               │
└─────────────┼────────────────────────────┼───────────────┘
              │                            │
              │  pg_dump (read-only)       │  pg_dump (read-only)
              ▼                            ▼
    ┌──────────────────┐        ┌──────────────────┐
    │  PostgreSQL      │        │  MinIO            │
    │  (prod)          │        │  bucket: backups  │
    │                  │        │  ├── hourly/      │
    │  user:           │        │  └── daily/       │
    │  instafuel_      │        │                  │
    │  backup (ro)     │        └──────────────────┘
    └──────────────────┘
```

**Les 2 services n'utilisent pas le même cron** → jamais de collision, jamais 2 pg_dump simultanés.

Le service hourly tourne à 1h05, 2h05, 3h05... Le service daily tourne à 0h00. (F1)

---

## Ce que contient MinIO après 24h

```
backups/
├── hourly/
│   ├── instafuel-prod-2026-07-15-19h05.dump  ← 22h
│   ├── instafuel-prod-2026-07-15-20h05.dump  ← 23h
│   ├── instafuel-prod-2026-07-15-21h05.dump  ← minuit+1
│   ├── instafuel-prod-2026-07-15-22h05.dump  ← +2h
│   ├── instafuel-prod-2026-07-15-23h05.dump  ← +3h
│   └── instafuel-prod-2026-07-16-00h05.dump  ← +4h (6 fichiers max)
│
└── daily/
    ├── instafuel-prod-2026-06-16.dump  ← J-30
    ├── instafuel-prod-2026-06-17.dump
    ├── ...
    └── instafuel-prod-2026-07-15.dump  ← hier minuit
```

Quand un nouveau backup hourly arrive (ex: 01h05), le plus vieux (19h05) est automatiquement supprimé. Fenêtre glissante de 6h avec granularité 1h.

---

## Les 12 failles que ce service colmate

Chaque faille a été identifiée en mode "pessimiste" : que se passe-t-il si ça casse au pire moment ?

### 🔴 Failles critiques — perte silencieuse de données

| # | Faille | Scénario réel | Colmatage | Liens |
|---|---|---|---|---|
| **F1** | Collision minuit | 2 pg_dump simultanés à 0h → contention locks, CPU x2 | Cron décalés : hourly à `5 * * * *`, daily à `0 0 * * *` | [L26-37] |
| **F2** | Dump vide | PostgreSQL répond mais renvoie 0 octet (corruption WAL) | Vérifie `taille > 0` + magic bytes `PGDMP` du format custom | [L107-122] |
| **F3** | Upload tronqué | Réseau coupé à 99% → MinIO a un fichier incomplet, mc cp exit 0 | `mc stat` + compare Content-Length avec taille locale. Retry 3x avec backoff 30s | [L127-152] |
| **F4** | Cleanup fou | Horloge dérive → `--older-than` cible tout → suppression de TOUS les backups | Compte avant/après. Si `deleted > kept * 2` → abort, exit 1 | [L157-179] |
| **F5** | Disque saturé | `/tmp` plein (container Railway) → pg_dump écrit 0 octet, exit 0 | `df /tmp` avant dump. Si < 500 Mo → exit 1 AVANT de dumper | [L84-96] |

### 🟡 Failles graves — panne non détectée

| # | Faille | Scénario réel | Colmatage | Liens |
|---|---|---|---|---|
| **F6** | Mot de passe exposé | `ps aux` montre `PGPASSWORD=secret` → n'importe quel process du container le lit | `.pgpass` 0600 + `unset PGPASSWORD` → rien dans `/proc` | [L100-113] |
| **F7** | Pas d'alerte | Backup foire à 3h du matin → personne ne sait → découvert au moment du crash | Script `exit 1` → Railway le log → activer les notifs Railway sur échec | [README#déploiement] |
| **F8** | Backup jamais testé | 30 jours de dumps, tous corrompus, personne n'a jamais essayé de restaurer | Doc restore dans ce README. **Test manuel 1x/mois obligatoire** | [Procédure restore](#procédure-de-restore) |
| **F9** | MinIO down | MinIO inaccessible → backup perdu, pas de fallback | Retry 3x backoff 30s. Si toujours down → laisse le dump dans `/tmp`, exit 1 | [L149-152] |

### 🟢 Failles modérées — robustesse

| # | Faille | Scénario réel | Colmatage | Liens |
|---|---|---|---|---|
| **F10** | Pas de health check | Impossible de savoir si le service tourne entre deux backups | `/tmp/last-backup.txt` avec timestamp + status + mode | [L184-189] |
| **F11** | Crash mi-dump | Railway kill le container → dump corrompu de 300 Mo reste dans `/tmp` | `trap cleanup EXIT` → `rm -f` le dump partiel. Prochain cron repart propre | [L74-79] |
| **F12** | Bug Alpine | `head -n -6` ne marche pas sur BusyBox (Alpine) → cleanup silencieusement cassé | `mc rm --older-than` utilise le timestamp serveur MinIO, pas de parsing shell | [L169] |

---

## Que se passe-t-il quand ça casse

### Scénario 1 : PostgreSQL est down à 14h05

```
14h05: pg_dump → exit 1
       script → exit 1
       Railway → log l'erreur, notifie (si configuré)
       Le hourly de 13h05 est toujours là
       Le daily de la veille est toujours là

Pertes: 1h de backup manquant (14h05). Le 15h05 réessaiera.
```

### Scénario 2 : MinIO est down

```
03h05: mc cp → échec → retry 1 (attente 30s)
       mc cp → échec → retry 2 (attente 30s)
       mc cp → échec → retry 3 (attente 30s)
       → exit 1
       Dump valide conservé dans /tmp (pas supprimé)

04h05: MinIO est revenu → upload reprend
```

### Scénario 3 : Quelqu'un `DROP TABLE transactions` à 10h30

```
Tu t'en rends compte à 10h45.

Option A — Restore depuis hourly/10h05 (perte: 40 min)
Option B — Restore depuis daily/minuit  (perte: 10h30, mais dump plus stable)

Les 2 sont disponibles. Tu choisis le moins pire.
```

### Scénario 4 : Compromission du compte Railway

```
Railway + BDD + services → tout perdu.

MAIS:
- MinIO est HORS Railway (minio-api.beta.geasscorp.com)
- Les backups daily/ et hourly/ sont intacts
- Tu provisionnes un nouveau Railway, tu restaures le dernier daily
- Pertes max: quelques heures
```

---

## Déploiement

### Prérequis

**1. Créer un utilisateur PostgreSQL read-only :**

```sql
-- ⚠️ Exécuter sur la base de PRODUCTION
CREATE USER instafuel_backup WITH PASSWORD '<motdepasse>';
GRANT pg_read_all_data TO instafuel_backup;
```

Pourquoi un utilisateur dédié ? Si le service backup est compromis, l'attaquant ne peut QUE lire. Pas de `DROP`, pas de `DELETE`.

**2. Créer une access key MinIO limitée :**

Créer une policy qui donne accès UNIQUEMENT au bucket `backups` :

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject", "s3:ListBucket", "s3:DeleteObject"],
      "Resource": ["arn:aws:s3:::backups", "arn:aws:s3:::backups/*"]
    }
  ]
}
```

Si cette clé fuit → l'attaquant voit les backups, pas les reçus, pas les docs véhicules, pas les logos.

### Variables d'environnement

**Communes aux 2 services :**

| Variable | Valeur | Note |
|---|---|---|
| `PGHOST` | `viaduct.proxy.rlwy.net` | Hôte PostgreSQL prod |
| `PGPORT` | `48229` | Port Railway PostgreSQL |
| `PGDATABASE` | `railway` | Nom de la base |
| `PGUSER` | `instafuel_backup` | Utilisateur read-only |
| `PGPASSWORD` | `***` | Mot de passe read-only |
| `NODE_ENV` | `production` | Suffixe des fichiers (`prod`) |
| `MINIO_ENDPOINT` | `minio-api.beta.geasscorp.com` | Hôte MinIO (hors Railway) |
| `MINIO_ACCESS_KEY` | `***` | Access key limitée bucket `backups` |
| `MINIO_SECRET_KEY` | `***` | Secret key |
| `MINIO_BUCKET` | `backups` | Bucket cible |

**Spécifiques à chaque service :**

| Variable | Service hourly | Service daily |
|---|---|---|
| `BACKUP_MODE` | `hourly` | `daily` |
| `RAILWAY_CRON_SCHEDULE` | `5 * * * *` | `0 0 * * *` |

### Mise en place

```bash
# 1. Cloner le repo
git clone https://github.com/carion21/instafuel-backup-service

# 2. Railway → New Project → Deploy from GitHub
#    → Sélectionner carion21/instafuel-backup-service

# 3. Créer le SERVICE 1 (hourly)
#    → Ajouter TOUTES les variables ci-dessus
#    → BACKUP_MODE=hourly
#    → RAILWAY_CRON_SCHEDULE=5 * * * *

# 4. Créer le SERVICE 2 (daily) — même repo GitHub
#    → Mêmes variables SAUF :
#    → BACKUP_MODE=daily
#    → RAILWAY_CRON_SCHEDULE=0 0 * * *

# 5. Vérifier les logs du premier cron
```

### Activer les notifications Railway

Dashboard Railway → service → Settings → Notifications →  
Activer les alertes sur **Deploy Failure** et **Cron Job Failure**.

Comme ça, si le backup échoue → tu reçois une notif (email/Slack/Discord selon config Railway).

---

## Procédure de restore

À faire **1x par mois** (F8). Prendre un backup daily au hasard, restaurer sur staging.

```bash
# 1. Lister les backups disponibles
mc alias set myminio https://minio-api.beta.geasscorp.com <KEY> <SECRET> --api S3v4
mc ls myminio/backups/hourly/
mc ls myminio/backups/daily/

# 2. Télécharger un backup (ex: daily d'hier)
mc cp myminio/backups/daily/instafuel-prod-2026-07-14.dump .

# 3. Restaurer sur une base vierge
createdb instafuel_restore_test
pg_restore -d instafuel_restore_test instafuel-prod-2026-07-14.dump

# 4. Vérifier l'intégrité
psql -d instafuel_restore_test -c "
  SELECT 'transactions' AS table_name, count(*) FROM transactions
  UNION ALL SELECT 'ledger_entries', count(*) FROM ledger_entries
  UNION ALL SELECT 'users', count(*) FROM users
  UNION ALL SELECT 'wallets', count(*) FROM wallets
  UNION ALL SELECT 'companies', count(*) FROM companies;
"

# 5. Nettoyer
dropdb instafuel_restore_test
rm instafuel-prod-2026-07-14.dump
```

---

## Test local

```bash
cp .env.example .env
# Éditer .env avec les vraies valeurs

# Builder l'image
docker build -t instafuel-backup .

# Tester le mode hourly
docker run --rm --env-file .env -e BACKUP_MODE=hourly instafuel-backup

# Tester le mode daily
docker run --rm --env-file .env -e BACKUP_MODE=daily instafuel-backup
```

---

## Fichiers

| Fichier | Rôle |
|---|---|
| `Dockerfile` | Image `postgres:18-alpine` + MinIO client `mc` |
| `backup.sh` | Script principal — 12 garde-fous, dual mode |
| `.env.example` | Template des variables d'environnement |
| `.gitignore` | Exclut `.env` et `*.dump` |
| `README.md` | Ce document |

---

## Licence

MIT — voir le repo principal [instafuel-workspace](https://github.com/carion21/instafuel-workspace).
