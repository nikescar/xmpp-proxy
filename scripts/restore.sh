#!/bin/bash
set -euo pipefail

if [ $# -ne 1 ]; then
    echo "Usage: $0 <backup-file.tar.gz>"
    echo ""
    echo "Example:"
    echo "  $0 /srv/xmpp/backups/xmpp-backup-20260714-030000.tar.gz"
    exit 1
fi

BACKUP_FILE="$1"

echo "=== XMPP Restore Script ==="
echo "Backup file: $BACKUP_FILE"
echo ""

# Verify backup file exists
if [ ! -f "$BACKUP_FILE" ]; then
    echo "ERROR: Backup file not found: $BACKUP_FILE"
    exit 1
fi

# Verify it's a valid tar.gz file
if ! tar tzf "$BACKUP_FILE" >/dev/null 2>&1; then
    echo "ERROR: Invalid or corrupted backup file"
    exit 1
fi

# Show backup contents
echo "Backup contents:"
tar tzf "$BACKUP_FILE" | head -20
echo ""

# Confirm with user
read -p "WARNING: This will overwrite existing data. Continue? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Restore cancelled."
    exit 0
fi

# Stop containers
echo ""
echo "Stopping Docker containers..."
docker compose down

# Extract backup
echo "Extracting backup to /srv/xmpp/..."
tar xzf "$BACKUP_FILE" -C /srv/xmpp

# Verify extraction
if [ -d /srv/xmpp/prosody ]; then
    echo "Restore completed successfully!"
    echo ""
    echo "Restored directories:"
    ls -lh /srv/xmpp/ | grep "^d"
else
    echo "ERROR: Restore failed - prosody directory not found"
    exit 1
fi

# Start containers
echo ""
echo "Starting Docker containers..."
docker compose up -d

echo ""
echo "=== Restore Complete ==="
echo "Check logs with: docker compose logs -f"
