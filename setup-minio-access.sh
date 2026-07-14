# Remplace par ton endpoint, MINIO_ROOT_USER et MINIO_ROOT_PASSWORD
mc alias set local "$MINIO_ENDPOINT" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"

# Crée la politique limitée au sous-chemin backups/
cat > /tmp/policy-instafuel-backup.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"],
      "Resource": ["arn:aws:s3:::instafuel/backups/*"]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": ["arn:aws:s3:::instafuel"]
    }
  ]
}
EOF

# Génère les clés API automatiquement
mc admin user svcacct add local "$MINIO_ROOT_USER" --policy /tmp/policy-instafuel-backup.json
