#!/bin/sh
# ============================================================
# setup-minio-access.sh
# Crée l'utilisateur MinIO dédié au backup service.
#
# Usage :
#   1. Copier ce script sur la machine qui a accès à MinIO
#   2. Remplacer les 3 variables ci-dessous
#   3. chmod +x setup-minio-access.sh && ./setup-minio-access.sh
#   4. Copier MINIO_ACCESS_KEY + MINIO_SECRET_KEY dans Railway
# ============================================================

# --- À REMPLACER ---
MINIO_ENDPOINT="https://minio-api.beta.geasscorp.com"
MINIO_ROOT_USER="UeXo7y4JnmLVdZyt"
MINIO_ROOT_PASSWORD="UXK1yFjvxrpd0de2AjHc6JACo4EO2Nsk"
BUCKET_PHYSIQUE="instafuel"

ACCESS_KEY="instafuel-backup-svc"
# --- FIN ---

# Générer un secret aléatoire
SECRET_KEY=$(openssl rand -hex 32 2>/dev/null || python3 -c "import secrets;print(secrets.token_hex(32))")

POLICY_FILE="/tmp/policy-instafuel-backup.json"

# 1. Se connecter à MinIO
echo "🔗 Connexion MinIO..."
mc alias set local "${MINIO_ENDPOINT}" "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" --api S3v4

# 2. Créer la politique limitée au sous-chemin backups/
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

# 3. Créer le compte de service
echo "🔑 Création service account..."
mc admin user svcacct add \
  --access-key "${ACCESS_KEY}" \
  --secret-key "${SECRET_KEY}" \
  --policy "${POLICY_FILE}" \
  local "${MINIO_ROOT_USER}"

rm -f "${POLICY_FILE}"

# 4. Vérifier que ça marche
echo ""
echo "🧪 Vérification..."
mc alias set backup-test "${MINIO_ENDPOINT}" "${ACCESS_KEY}" "${SECRET_KEY}" --api S3v4

echo "  → Test accès backups/ (doit marcher) :"
if mc ls "backup-test/${BUCKET_PHYSIQUE}/backups/" >/dev/null 2>&1; then
  echo "    ✅ OK"
else
  echo "    ⚠️  Attention"
fi

echo "  → Test accès receipts/ (doit échouer) :"
if mc ls "backup-test/${BUCKET_PHYSIQUE}/receipts/" >/dev/null 2>&1; then
  echo "    ❌ ÉCHEC — la clé a trop de droits !"
else
  echo "    ✅ AccessDenied (attendu)"
fi

mc alias rm backup-test >/dev/null 2>&1

echo ""
echo "============================================"
echo "✅ Compte backup créé."
echo ""
echo "Copie ces 2 valeurs dans Railway :"
echo ""
echo "  MINIO_ACCESS_KEY=${ACCESS_KEY}"
echo "  MINIO_SECRET_KEY=${SECRET_KEY}"
echo "============================================"
