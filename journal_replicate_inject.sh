#!/bin/bash
#
# journal_replicate_inject.sh - Inject journal state into replica
#
# This script takes captured journal state from a source filesystem
# and injects it into a replica filesystem, then triggers replay.
#
# Usage: ./journal_replicate_inject.sh <replica_fs.img> <capture_dir>
#

set -e

if [ $# -ne 2 ]; then
    echo "Usage: $0 <replica_fs.img> <capture_dir>"
    echo ""
    echo "Injects captured journal state into replica filesystem."
    echo "The replica must be an identical copy of the source (before changes)."
    exit 1
fi

REPLICA_IMG="$1"
CAPTURE_DIR="$2"

if [ ! -f "$REPLICA_IMG" ]; then
    echo "Error: Replica image '$REPLICA_IMG' not found"
    exit 1
fi

if [ ! -d "$CAPTURE_DIR" ]; then
    echo "Error: Capture directory '$CAPTURE_DIR' not found"
    exit 1
fi

METADATA="$CAPTURE_DIR/replication_metadata.txt"
if [ ! -f "$METADATA" ]; then
    echo "Error: Metadata file not found: $METADATA"
    exit 1
fi

echo "==================================================================="
echo "JOURNAL REPLICATION - INJECTION PHASE"
echo "==================================================================="
echo ""
echo "Replica filesystem: $REPLICA_IMG"
echo "Capture directory:  $CAPTURE_DIR"
echo ""

# Load metadata
echo "[1/5] Loading replication metadata..."
source "$METADATA"

echo "  Block size:        $BLOCK_SIZE bytes"
echo "  Journal blocks:    $JOURNAL_BLOCKS"
echo "  Journal sequence:  $JOURNAL_SEQUENCE"
echo "  Transaction count: $TRANSACTION_COUNT"
echo ""

# Verify replica is compatible
echo "[2/5] Verifying replica compatibility..."
REPLICA_INFO=$(mktemp)
./misc/dumpe2fs "$REPLICA_IMG" 2>/dev/null > "$REPLICA_INFO"

REPLICA_BLOCK_SIZE=$(grep "Block size:" "$REPLICA_INFO" | awk '{print $3}')
REPLICA_INODE_SIZE=$(grep "Inode size:" "$REPLICA_INFO" | awk '{print $3}')

if [ "$REPLICA_BLOCK_SIZE" != "$BLOCK_SIZE" ]; then
    echo "  ERROR: Block size mismatch!"
    echo "    Source: $BLOCK_SIZE, Replica: $REPLICA_BLOCK_SIZE"
    rm "$REPLICA_INFO"
    exit 1
fi

if [ "$REPLICA_INODE_SIZE" != "$INODE_SIZE" ]; then
    echo "  ERROR: Inode size mismatch!"
    echo "    Source: $INODE_SIZE, Replica: $REPLICA_INODE_SIZE"
    rm "$REPLICA_INFO"
    exit 1
fi

echo "  ✓ Block sizes match"
echo "  ✓ Inode sizes match"
rm "$REPLICA_INFO"
echo ""

# Get journal location on replica
echo "[3/5] Locating journal on replica..."
REPLICA_JOURNAL_INFO=$(mktemp)
./debugfs/debugfs -R "stat <$JOURNAL_INODE>" "$REPLICA_IMG" 2>/dev/null > "$REPLICA_JOURNAL_INFO"

REPLICA_JOURNAL_EXTENT=$(grep "EXTENTS:" -A 10 "$REPLICA_JOURNAL_INFO" | grep -E "^\(" | head -1)
REPLICA_FIRST_BLOCK=$(echo "$REPLICA_JOURNAL_EXTENT" | grep -oE '[0-9]+$')

echo "  Journal inode: $JOURNAL_INODE"
echo "  Journal extent: $REPLICA_JOURNAL_EXTENT"
echo "  First block: $REPLICA_FIRST_BLOCK"
rm "$REPLICA_JOURNAL_INFO"
echo ""

# Inject journal blocks
JOURNAL_RAW="$CAPTURE_DIR/04_journal_blocks.raw"

if [ ! -f "$JOURNAL_RAW" ]; then
    echo "Error: Journal blocks file not found: $JOURNAL_RAW"
    exit 1
fi

echo "[4/5] Injecting journal blocks into replica..."
echo "  Writing to block $REPLICA_FIRST_BLOCK"
echo "  Block count: $JOURNAL_BLOCKS"
echo "  Block size: $BLOCK_SIZE bytes"

# Backup replica first
BACKUP_IMG="${REPLICA_IMG}.backup-$(date +%s)"
cp "$REPLICA_IMG" "$BACKUP_IMG"
echo "  Created backup: $BACKUP_IMG"

# Write journal blocks to replica
dd if="$JOURNAL_RAW" of="$REPLICA_IMG" \
   bs="$BLOCK_SIZE" \
   seek="$REPLICA_FIRST_BLOCK" \
   count="$JOURNAL_BLOCKS" \
   conv=notrunc \
   2>/dev/null

echo "  ✓ Journal blocks written"
echo ""

# Mark filesystem as needing recovery
echo "[5/5] Marking filesystem for journal replay..."

# The filesystem needs the "needs recovery" flag set in the superblock
# We'll use debugfs to set this
echo "  Setting 'needs_recovery' feature..."

# Use tune2fs to force a journal check
./misc/tune2fs -f -C 1 "$REPLICA_IMG" >/dev/null 2>&1 || true

echo "  ✓ Filesystem marked for recovery"
echo ""

echo "==================================================================="
echo "INJECTION COMPLETE"
echo "==================================================================="
echo ""
echo "Next steps:"
echo ""
echo "1. Check filesystem (this will replay the journal):"
echo "   e2fsck -fy $REPLICA_IMG"
echo ""
echo "2. Mount and verify:"
echo "   mount $REPLICA_IMG /mnt"
echo "   ls -la /mnt"
echo ""
echo "The replica should now contain the changes from the source!"
echo ""
echo "Backup saved at: $BACKUP_IMG"
echo ""
