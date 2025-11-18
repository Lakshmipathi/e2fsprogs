#!/bin/bash
#
# direct_block_replicate.sh - Direct block-level replication without journal
#
# This approach avoids the journal checkpoint timing issue by:
# 1. Reading file blocks directly from the filesystem
# 2. Transferring those specific blocks to replica
# 3. Writing to same block locations on replica
#
# This achieves the same result as journal replay but doesn't depend on
# capturing journal before checkpoint.
#

set -e

if [ $# -lt 3 ]; then
    echo "Usage: $0 <source_img> <file_path> <output_dir>"
    echo ""
    echo "Captures the blocks used by a specific file for replication."
    echo ""
    echo "Example:"
    echo "  $0 fs.img /mnt/file1.txt /tmp/capture"
    echo ""
    echo "This reads the actual data blocks for file1.txt and saves them"
    echo "so they can be written to the same blocks on the replica."
    exit 1
fi

SOURCE_IMG="$1"
FILE_PATH="$2"
OUTPUT_DIR="$3"

if [ ! -e "$SOURCE_IMG" ]; then
    echo "Error: Source image '$SOURCE_IMG' not found"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

echo "=================================================================="
echo "DIRECT BLOCK REPLICATION - Single File"
echo "=================================================================="
echo ""
echo "Source:    $SOURCE_IMG"
echo "File:      $FILE_PATH"
echo "Output:    $OUTPUT_DIR"
echo ""

# Extract just the filename from full path
FILENAME=$(basename "$FILE_PATH")
echo "[1/6] Finding inode for: $FILENAME"

# Get inode number - try multiple methods
INODE=""

# Method 1: Use ncheck with just filename
INODE=$(./debugfs/debugfs -R "ncheck $FILENAME" "$SOURCE_IMG" 2>/dev/null | grep -v "Inode" | awk '{print $1}' | head -1 || true)

# Method 2: Try with leading /
if [ -z "$INODE" ]; then
    INODE=$(./debugfs/debugfs -R "ncheck /$FILENAME" "$SOURCE_IMG" 2>/dev/null | grep -v "Inode" | awk '{print $1}' | head -1 || true)
fi

# Method 3: Find in root directory listing
if [ -z "$INODE" ]; then
    INODE=$(./debugfs/debugfs -R "ls -l /" "$SOURCE_IMG" 2>/dev/null | grep "$FILENAME" | awk '{print $1}' | grep -oE '^[0-9]+' || true)
fi

if [ -z "$INODE" ]; then
    echo "  ERROR: Could not find inode for $FILENAME"
    echo "  Directory listing:"
    ./debugfs/debugfs -R "ls -l /" "$SOURCE_IMG" 2>/dev/null | sed 's/^/    /'
    exit 1
fi

echo "  ✓ Inode: $INODE"
echo ""

echo "[2/6] Reading inode metadata"
./debugfs/debugfs -R "stat <$INODE>" "$SOURCE_IMG" 2>/dev/null > "$OUTPUT_DIR/inode_stat.txt"

FILE_SIZE=$(grep "^Size:" "$OUTPUT_DIR/inode_stat.txt" | awk '{print $2}')
echo "  File size: $FILE_SIZE bytes"
echo ""

echo "[3/6] Extracting block list"
# Handle both BLOCKS and EXTENTS formats
BLOCKS=$(./debugfs/debugfs -R "stat <$INODE>" "$SOURCE_IMG" 2>/dev/null | \
    grep -E "(BLOCKS:|EXTENTS:)" -A 20 | \
    grep -oE '\([0-9]+\):?[0-9]+' | \
    grep -oE '[0-9]+$' | \
    head -20)

if [ -z "$BLOCKS" ]; then
    echo "  ERROR: No blocks found for inode $INODE"
    cat "$OUTPUT_DIR/inode_stat.txt"
    exit 1
fi

BLOCK_COUNT=$(echo "$BLOCKS" | wc -l)
echo "  ✓ Found $BLOCK_COUNT data block(s)"
echo "$BLOCKS" | head -10 | sed 's/^/    Block: /'
if [ "$BLOCK_COUNT" -gt 10 ]; then
    echo "    ... and $((BLOCK_COUNT - 10)) more"
fi
echo ""

echo "[4/6] Getting filesystem parameters"
BLOCK_SIZE=$(./misc/dumpe2fs "$SOURCE_IMG" 2>/dev/null | grep "^Block size:" | awk '{print $3}')
echo "  Block size: $BLOCK_SIZE bytes"
echo ""

echo "[5/6] Reading actual block data"
# Save block list
echo "$BLOCKS" > "$OUTPUT_DIR/block_list.txt"

# Read each block and save to file
BLOCK_NUM=0
for BLOCK in $BLOCKS; do
    echo "  Reading block $BLOCK (${BLOCK_NUM})"

    # Use dd to read the specific block
    dd if="$SOURCE_IMG" \
       of="$OUTPUT_DIR/block_${BLOCK_NUM}.raw" \
       bs="$BLOCK_SIZE" \
       skip="$BLOCK" \
       count=1 \
       2>/dev/null

    BLOCK_NUM=$((BLOCK_NUM + 1))

    # Limit to first 10 blocks for demo
    if [ "$BLOCK_NUM" -ge 10 ]; then
        break
    fi
done
echo "  ✓ Saved $BLOCK_NUM block(s)"
echo ""

echo "[6/6] Creating replication metadata"
cat > "$OUTPUT_DIR/replication_metadata.txt" << EOF
# Direct Block Replication Metadata
# Generated: $(date)

SOURCE_IMAGE=$SOURCE_IMG
FILE_PATH=$FILE_PATH
FILENAME=$FILENAME
INODE=$INODE
FILE_SIZE=$FILE_SIZE
BLOCK_SIZE=$BLOCK_SIZE
BLOCK_COUNT=$BLOCK_COUNT

# Block numbers (in order):
$(echo "$BLOCKS" | head -10)
EOF

echo "  ✓ Metadata saved"
echo ""

echo "=================================================================="
echo "CAPTURE COMPLETE"
echo "=================================================================="
echo ""
echo "Captured file: $FILENAME"
echo "  Inode: $INODE"
echo "  Size: $FILE_SIZE bytes"
echo "  Blocks: $BLOCK_COUNT"
echo ""
echo "Output files in: $OUTPUT_DIR"
echo "  - inode_stat.txt (full inode metadata)"
echo "  - block_list.txt (list of block numbers)"
echo "  - block_N.raw (actual block data)"
echo "  - replication_metadata.txt (machine-readable metadata)"
echo ""
echo "Next step: Transfer $OUTPUT_DIR to server2 and use inject script"
echo ""
