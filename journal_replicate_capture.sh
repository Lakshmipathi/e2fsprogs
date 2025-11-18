#!/bin/bash
#
# journal_replicate_capture.sh - Capture journal state for replication
#
# This script captures the current journal state from a source filesystem
# so it can be replayed on a replica filesystem.
#
# Usage: ./journal_replicate_capture.sh <fs.img> <output_dir>
#

set -e

if [ $# -ne 2 ]; then
    echo "Usage: $0 <source_fs.img> <output_dir>"
    echo ""
    echo "Captures journal state from source filesystem for replication."
    echo "The output can be transferred to a replica and replayed."
    exit 1
fi

SOURCE_IMG="$1"
OUTPUT_DIR="$2"

if [ ! -f "$SOURCE_IMG" ]; then
    echo "Error: Source image '$SOURCE_IMG' not found"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

echo "==================================================================="
echo "JOURNAL REPLICATION - CAPTURE PHASE"
echo "==================================================================="
echo ""
echo "Source filesystem: $SOURCE_IMG"
echo "Output directory:  $OUTPUT_DIR"
echo ""

# Get filesystem info
echo "[1/6] Reading filesystem superblock..."
SUPERBLOCK_INFO="$OUTPUT_DIR/00_filesystem_superblock.txt"
./misc/dumpe2fs "$SOURCE_IMG" 2>/dev/null > "$SUPERBLOCK_INFO"

# Extract key filesystem parameters
BLOCK_SIZE=$(grep "Block size:" "$SUPERBLOCK_INFO" | awk '{print $3}')
INODE_SIZE=$(grep "Inode size:" "$SUPERBLOCK_INFO" | awk '{print $3}')
JOURNAL_INODE=$(grep "Journal inode:" "$SUPERBLOCK_INFO" | awk '{print $3}')
JOURNAL_BACKUP=$(grep "Journal backup:" "$SUPERBLOCK_INFO" | awk '{print $3}')

echo "  Block size:     $BLOCK_SIZE bytes"
echo "  Inode size:     $INODE_SIZE bytes"
echo "  Journal inode:  $JOURNAL_INODE"
echo "  Journal backup: $JOURNAL_BACKUP"
echo ""

# Get journal superblock
echo "[2/6] Reading journal superblock..."
JOURNAL_SUPER="$OUTPUT_DIR/01_journal_superblock.txt"
./misc/dumpe2fs "$SOURCE_IMG" 2>/dev/null | grep -A 20 "^Journal" > "$JOURNAL_SUPER"

# Extract journal parameters
JOURNAL_SIZE=$(grep "Total journal size:" "$JOURNAL_SUPER" | awk '{print $4}' | tr -d 'M')
JOURNAL_BLOCKS=$(grep "Total journal blocks:" "$JOURNAL_SUPER" | awk '{print $4}')
JOURNAL_SEQ=$(grep "Journal sequence:" "$JOURNAL_SUPER" | awk '{print $3}')
JOURNAL_START=$(grep "Journal start:" "$JOURNAL_SUPER" | awk '{print $3}')

echo "  Journal size:   ${JOURNAL_SIZE}M"
echo "  Journal blocks: $JOURNAL_BLOCKS"
echo "  Sequence:       $JOURNAL_SEQ"
echo "  Start block:    $JOURNAL_START"
echo ""

# Dump full journal contents
echo "[3/6] Dumping journal transactions..."
JOURNAL_DUMP="$OUTPUT_DIR/02_journal_dump.txt"
./debugfs/debugfs -R "logdump -a" "$SOURCE_IMG" 2>/dev/null > "$JOURNAL_DUMP"

# Count transactions
TRANSACTION_COUNT=$(grep -c "Found expected sequence" "$JOURNAL_DUMP" || echo "0")
echo "  Transactions found: $TRANSACTION_COUNT"

# Check if journal is empty
if grep -q "No magic number at block 1: end of journal" "$JOURNAL_DUMP"; then
    echo "  WARNING: Journal appears to be empty (checkpointed)!"
    echo "  This means all transactions were committed to the filesystem."
    echo "  For replication to work, you need uncommitted transactions."
    echo ""
    echo "  Tips to preserve journal:"
    echo "    1. Use mount -o commit=9999 (delays checkpoint)"
    echo "    2. Capture immediately after sync (before checkpoint)"
    echo "    3. Or don't call sync at all (let commit= timer handle it)"
fi
echo ""

# Get journal inode information (to find journal blocks on disk)
echo "[4/6] Locating journal blocks on disk..."
JOURNAL_INODE_INFO="$OUTPUT_DIR/03_journal_inode.txt"
./debugfs/debugfs -R "stat <$JOURNAL_INODE>" "$SOURCE_IMG" 2>/dev/null > "$JOURNAL_INODE_INFO"

# Extract journal block locations
JOURNAL_EXTENT=$(grep "EXTENTS:" -A 10 "$JOURNAL_INODE_INFO" | grep -E "^\(")
echo "  Journal extents: $JOURNAL_EXTENT" | head -3
echo ""

# Create metadata file for transfer
echo "[5/6] Creating replication metadata..."
METADATA="$OUTPUT_DIR/replication_metadata.txt"
cat > "$METADATA" <<EOF
# Journal Replication Metadata
# Generated: $(date)
# Source: $SOURCE_IMG

# Filesystem Parameters
BLOCK_SIZE=$BLOCK_SIZE
INODE_SIZE=$INODE_SIZE
JOURNAL_INODE=$JOURNAL_INODE

# Journal State
JOURNAL_SIZE=$JOURNAL_SIZE
JOURNAL_BLOCKS=$JOURNAL_BLOCKS
JOURNAL_SEQUENCE=$JOURNAL_SEQ
JOURNAL_START=$JOURNAL_START

# Journal Location on Disk
JOURNAL_EXTENTS="$JOURNAL_EXTENT"

# Transaction Count
TRANSACTION_COUNT=$TRANSACTION_COUNT
EOF

echo "  Metadata saved to: $METADATA"
echo ""

# Extract journal blocks as raw data
echo "[6/6] Extracting journal blocks..."
JOURNAL_RAW="$OUTPUT_DIR/04_journal_blocks.raw"

# Get the first extent's starting block
FIRST_BLOCK=$(echo "$JOURNAL_EXTENT" | head -1 | grep -oE '[0-9]+$')

if [ -n "$FIRST_BLOCK" ]; then
    echo "  Extracting from block $FIRST_BLOCK, count $JOURNAL_BLOCKS"
    echo "  Block size: $BLOCK_SIZE bytes"

    # Extract journal blocks using dd
    dd if="$SOURCE_IMG" of="$JOURNAL_RAW" \
       bs="$BLOCK_SIZE" \
       skip="$FIRST_BLOCK" \
       count="$JOURNAL_BLOCKS" \
       2>/dev/null

    RAW_SIZE=$(stat -f "%z" "$JOURNAL_RAW" 2>/dev/null || stat -c "%s" "$JOURNAL_RAW")
    echo "  Extracted: $RAW_SIZE bytes"
else
    echo "  Warning: Could not determine journal block location"
fi

echo ""
echo "==================================================================="
echo "CAPTURE COMPLETE"
echo "==================================================================="
echo ""
echo "Generated files in $OUTPUT_DIR:"
ls -lh "$OUTPUT_DIR" | tail -n +2 | awk '{print "  " $9 " (" $5 ")"}'
echo ""
echo "Transfer these files to server2, then run:"
echo "  ./journal_replicate_inject.sh <replica_fs.img> $OUTPUT_DIR"
echo ""
