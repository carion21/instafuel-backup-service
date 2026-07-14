# Remplace par ton endpoint, MINIO_ROOT_USER et MINIO_ROOT_PASSWORD
mc alias set local http://localhost:9000 UeXo7y4JnmLVdZyt UXK1yFjvxrpd0de2AjHc6JACo4EO2Nsk

# Crée la politique limitée au sous-chemin backups/
cat > /tmp/policy-backup.json <<EOF
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
mc admin user svcacct add local UeXo7y4JnmLVdZyt --policy /tmp/policy-backup.json
