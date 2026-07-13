#!/bin/bash
set -euo pipefail

BACKUP_DIR="/srv/xmpp/backups"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_FILE="$BACKUP_DIR/xmpp-backup-$TIMESTAMP.tar.gz"

echo "=== XMPP Backup Script ==="
echo "Timestamp: $TIMESTAMP"
echo ""

# Create backup directory if it doesn't exist
mkdir -p "$BACKUP_DIR"

# Check if data directories exist
if [ ! -d /srv/xmpp/prosody ]; then
    echo "ERROR: /srv/xmpp/prosody not found"
    exit 1
fi

# Create backup archive
echo "Creating backup archive..."
tar czf "$BACKUP_FILE" \
    --exclude='/srv/xmpp/logs/*' \
    -C /srv/xmpp \
    prosody \
    certs \
    fail2ban \
    acme

# Verify backup was created
if [ -f "$BACKUP_FILE" ]; then
    BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
    echo "Backup created successfully!"
    echo "File: $BACKUP_FILE"
    echo "Size: $BACKUP_SIZE"
    echo ""

    # List contents
    echo "Archive contents:"
    tar tzf "$BACKUP_FILE" | head -20

    # Cleanup old backups (keep last 7 days)
    echo ""
    echo "Cleaning up old backups (keeping last 7 days)..."
    find "$BACKUP_DIR" -name "xmpp-backup-*.tar.gz" -mtime +7 -delete

    echo ""
    echo "Remaining backups:"
    ls -lh "$BACKUP_DIR"/xmpp-backup-*.tar.gz 2>/dev/null || echo "  (none)"
else
    echo "ERROR: Backup file not created"
    exit 1
fi

echo ""
echo "=== Backup Complete ==="
