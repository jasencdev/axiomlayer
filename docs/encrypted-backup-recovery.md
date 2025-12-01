# Encrypted Backup Recovery

## Overview

Full homelab backups are stored on LUKS-encrypted USB drives. This document describes how to access and restore from these backups.

## Backup Contents

```
100-full-backup/
├── databases/          # PostgreSQL dumps
│   ├── authentik.sql   # SSO/identity provider
│   ├── outline.sql     # Documentation wiki
│   ├── n8n.sql         # Workflow automation
│   └── openwebui.sql   # AI chat interface
├── k8s/                # Kubernetes resources by namespace
│   ├── argocd/
│   ├── authentik/
│   ├── monitoring/
│   └── ...
├── repo/               # Full axiomlayer git repository
│   └── axiomlayer/
└── secrets/            # Sealed Secrets keys
    ├── sealed-secrets-keys.yaml
    └── sealed-secrets-pub.pem
```

## Accessing Encrypted Drives

### 1. Plug in the USB drive and identify it

```bash
lsblk -o NAME,SIZE,FSTYPE,LABEL
```

Look for the drive (likely `/dev/sdX1` with `crypto_LUKS` type).

### 2. Unlock the encrypted volume

```bash
sudo cryptsetup luksOpen /dev/sdX1 backup_crypt
```

Enter the password when prompted.

### 3. Mount the decrypted volume

```bash
sudo mkdir -p /mnt/backup
sudo mount /dev/mapper/backup_crypt /mnt/backup
```

### 4. Access the backup

```bash
ls /mnt/backup/100-full-backup/
```

## Recovery Procedures

### Restore Kubernetes Resources

```bash
# Apply all resources for a specific namespace
kubectl apply -f /mnt/backup/100-full-backup/k8s/<namespace>/resources.yaml
```

### Restore PostgreSQL Database

```bash
# Example: Restore Authentik database
# Find your actual PostgreSQL pod name using a label selector (recommended):
kubectl get pods -n authentik -l app=postgres
# Then, replace <authentik-db-pod> below with the correct pod name:
kubectl exec -i -n authentik <authentik-db-pod> -c postgres -- psql -U postgres -d authentik < /mnt/backup/100-full-backup/databases/authentik.sql
```

### Restore Sealed Secrets Keys

**Critical**: Required to decrypt existing SealedSecrets after cluster rebuild.

```bash
kubectl apply -f /mnt/backup/100-full-backup/secrets/sealed-secrets-keys.yaml
kubectl rollout restart deployment/sealed-secrets-controller -n kube-system
```

### Restore Git Repository

```bash
cp -r /mnt/backup/100-full-backup/repo/axiomlayer ~/axiomlayer-restored
cd ~/axiomlayer-restored
git status
```

## Safely Unmounting

```bash
sudo umount /mnt/backup
sudo cryptsetup luksClose backup_crypt
```

## Drive Identification

| Label | Size | Description |
|-------|------|-------------|
| backup1 | 28.9G | Primary encrypted backup |
| backup2 | 57.7G | Secondary encrypted backup |

## Backup Locations

1. **UNAS** - `/k8s-backup/100-full-backup/` (network, unencrypted)
2. **USB backup1** - LUKS encrypted, 28.9G drive
3. **USB backup2** - LUKS encrypted, 57.7G drive

## Notes

- Last backup: 2024-11-30 (example)
- Encryption: LUKS2
- Filesystem: ext4
- Password stored in 1Password vault under 'Backup Encryption Keys' (not in this document)
