#!/bin/bash
#
# direct_block_inject.sh - Inject captured blocks into replica filesystem
#
# This script writes the captured file blocks to the same block locations
# on the replica filesystem, achieving file replication without journal replay.
#

set -e

if [ $# -lt 2 ]; then
    echo "Usage: $0 <replica_img> <capture_dir>"
    echo ""
    echo "Injects captured blocks into replica filesystem."
    echo ""
    echo "Example:"
    echo "  $0 server2_fs.img /tmp/capture"
    echo ""
    echo "IMPORTANT: Replica must be unmounted!"
    exit 1
fi

REPLICA_IMG="$1"
CAPTURE_DIR="$2"

if [ ! -e "$REPLICA_IMG" ]; then
    echo "Error: Replica image '$REPLICA_IMG' not found"
    exit 1
fi

if [ ! -d "$CAPTURE_DIR" ]; then
    echo "Error: Capture directory '$CAPTURE_DIR' not found"
    exit 1
fi

if [ ! -f "$CAPTURE_DIR/replication_metadata.txt" ]; then
    echo "Error: replication_metadata.txt not found in $CAPTURE_DIR"
    exit 1
fi

echo "=================================================================="
echo "DIRECT BLOCK INJECTION"
echo "=================================================================="
echo ""
echo "Replica:  $REPLICA_IMG"
echo "Capture:  $CAPTURE_DIR"
echo ""

# Load metadata
source "$CAPTURE_DIR/replication_metadata.txt"

echo "[1/5] Verifying replica compatibility"
REPLICA_BLOCK_SIZE=$(./misc/dumpe2fs "$REPLICA_IMG" 2>/dev/null | grep "^Block size:" | awk '{print $3}')

if [ "$REPLICA_BLOCK_SIZE" != "$BLOCK_SIZE" ]; then
    echo "  ERROR: Block size mismatch!"
    echo "    Source: $BLOCK_SIZE"
    echo "    Replica: $REPLICA_BLOCK_SIZE"
    exit 1
fi

echo "  ✓ Block sizes match: $BLOCK_SIZE bytes"
echo ""

echo "[2/5] Checking if replica is mounted"
if mount | grep -q "$REPLICA_IMG"; then
    echo "  ERROR: Replica is currently mounted!"
    echo "  Please unmount before injection:"
    mount | grep "$REPLICA_IMG" | sed 's/^/    /'
    exit 1
fi
echo "  ✓ Replica is not mounted"
echo ""

echo "[3/5] Creating backup"
BACKUP="${REPLICA_IMG}.backup_$(date +%s)"
cp "$REPLICA_IMG" "$BACKUP"
echo "  ✓ Backup created: $BACKUP"
echo ""

echo "[4/5] Finding target inode on replica"
# The target file should already exist at the same inode on replica
# (because we started from identical filesystems)
# But we verify this:

REPLICA_INODE=$(./debugfs/debugfs -R "ncheck $FILENAME" "$REPLICA_IMG" 2>/dev/null | grep -v "Inode" | awk '{print $1}' | head -1 || true)

if [ -z "$REPLICA_INODE" ]; then
    echo "  ⚠ File $FILENAME not found on replica"
    echo "  This is expected if it's a new file"
    echo "  We'll write to the same blocks used on source"
else
    echo "  ✓ Found $FILENAME at inode: $REPLICA_INODE"

    if [ "$REPLICA_INODE" != "$INODE" ]; then
        echo "  ⚠ WARNING: Inode mismatch!"
        echo "    Source inode: $INODE"
        echo "    Replica inode: $REPLICA_INODE"
        echo "  This means filesystems diverged!"
    fi
fi
echo ""

echo "[5/5] Writing blocks to replica"
# Read block list and write each block
BLOCK_NUM=0
while read -r BLOCK; do
    if [ ! -f "$CAPTURE_DIR/block_${BLOCK_NUM}.raw" ]; then
        echo "  Skipping block $BLOCK (no data file)"
        BLOCK_NUM=$((BLOCK_NUM + 1))
        continue
    fi

    echo "  Writing block $BLOCK (file block ${BLOCK_NUM})"

    # Use dd to write the specific block
    dd if="$CAPTURE_DIR/block_${BLOCK_NUM}.raw" \
       of="$REPLICA_IMG" \
       bs="$BLOCK_SIZE" \
       seek="$BLOCK" \
       count=1 \
       conv=notrunc \
       2>/dev/null

    BLOCK_NUM=$((BLOCK_NUM + 1))
done < "$CAPTURE_DIR/block_list.txt"

echo "  ✓ Wrote $BLOCK_NUM block(s) to replica"
echo ""

echo "=================================================================="
echo "INJECTION COMPLETE"
echo "=================================================================="
echo ""
echo "Injected file: $FILENAME"
echo "  Blocks written: $BLOCK_NUM"
echo "  Target blocks: $(cat $CAPTURE_DIR/block_list.txt | head -$BLOCK_NUM | tr '\n' ' ')"
echo ""
echo "Backup saved: $BACKUP"
echo ""
echo "Next step: Run e2fsck on replica and mount to verify"
echo "  ./e2fsck/e2fsck -fy $REPLICA_IMG"
echo "  mount $REPLICA_IMG /mnt"
echo "  cat /mnt/$FILENAME"
echo ""
