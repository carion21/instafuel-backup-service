#!/bin/sh
# ============================================================
# setup-minio-access.sh
# Crée l'utilisateur MinIO dédié au backup service.
# MinIO génère les clés automatiquement.
#
# Usage :
#   1. Remplacer les 3 variables ci-dessous
#   2. chmod +x setup-minio-access.sh && ./setup-minio-access.sh
#   3. Copier Access Key + Secret Key affichés → Railway
# ============================================================

# --- À REMPLACER ---
MINIO_ENDPOINT="https://minio-api.beta.geasscorp.com"
MINIO_ROOT_USER="UeXo7y4JnmLVdZyt"
MINIO_ROOT_PASSWORD="UXK1yFjvxrpd0de2AjHc6JACo4EO2Nsk"
BUCKET_PHYSIQUE="instafuel"
# --- FIN ---

POLICY_FILE="/tmp/policy-instafuel-backup.json"

# 1. Connexion MinIO
echo "🔗 Connexion MinIO..."
mc alias set local "${MINIO_ENDPOINT}" "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" --api S3v4

# 2. Politique limitée à instafuel/backups/
echo "📝 Création politique backup-only..."
cat > "${POLICY_FILE}" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject"
      ],
      "Resource": "arn:aws:s3:::${BUCKET_PHYSIQUE}/backups/*"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": "arn:aws:s3:::${BUCKET_PHYSIQUE}"
    }
  ]
}
EOF

# 3. Créer service account — MinIO génère les clés
echo "🔑 Création service account..."
OUTPUT=$(mc admin user svcacct add \
  --policy "${POLICY_FILE}" \
  local "${MINIO_ROOT_USER}")

rm -f "${POLICY_FILE}"

# Extraire les clés de la sortie
ACCESS_KEY=$(echo "$OUTPUT" | grep -o '"accessKey"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
SECRET_KEY=$(echo "$OUTPUT" | grep -o '"secretKey"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')

echo ""
echo "============================================"
echo "✅ Compte backup créé."
echo ""
echo "Copie ces 2 valeurs dans Railway :"
echo ""
echo "  MINIO_ACCESS_KEY=${ACCESS_KEY}"
echo "  MINIO_SECRET_KEY=${SECRET_KEY}"
echo "============================================"
