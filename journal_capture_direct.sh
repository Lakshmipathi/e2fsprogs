#!/bin/bash
#
# journal_capture_direct.sh - Capture journal using direct block reads
#
# This approach reads journal blocks DIRECTLY using dd with O_DIRECT flag,
# bypassing the kernel's filesystem cache. This should avoid triggering
# checkpoints that happen when we use debugfs logdump.
#
# Key insight: debugfs might be triggering checkpoints by accessing the
# filesystem. Direct block reads with dd bypass this entirely.
#

set -e

if [ $# -lt 2 ]; then
    echo "Usage: $0 <source_img> <output_dir>"
    echo ""
    echo "Captures journal state using direct block reads (no debugfs)."
    echo ""
    echo "Example:"
    echo "  $0 fs.img /tmp/capture"
    echo ""
    exit 1
fi

SOURCE_IMG="$1"
OUTPUT_DIR="$2"

if [ ! -e "$SOURCE_IMG" ]; then
    echo "Error: Source image '$SOURCE_IMG' not found"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

echo "=================================================================="
echo "DIRECT JOURNAL CAPTURE (Bypassing debugfs)"
echo "=================================================================="
echo ""
echo "Source: $SOURCE_IMG"
echo "Output: $OUTPUT_DIR"
echo ""
echo "This method reads journal blocks directly with dd, avoiding any"
echo "filesystem cache operations that might trigger checkpointing."
echo ""

echo "[1/6] Reading filesystem superblock"
./misc/dumpe2fs "$SOURCE_IMG" 2>/dev/null > "$OUTPUT_DIR/00_filesystem_info.txt"

BLOCK_SIZE=$(grep "^Block size:" "$OUTPUT_DIR/00_filesystem_info.txt" | awk '{print $3}')
echo "  Block size: $BLOCK_SIZE"
echo ""

echo "[2/6] Finding journal location"
./misc/dumpe2fs "$SOURCE_IMG" 2>/dev/null | grep -A 30 "^Journal" > "$OUTPUT_DIR/01_journal_info.txt"

JOURNAL_INODE=$(grep "^Journal inode:" "$OUTPUT_DIR/01_journal_info.txt" | awk '{print $3}')
JOURNAL_BLOCKS=$(grep "^Journal blocks:" "$OUTPUT_DIR/01_journal_info.txt" | awk '{print $3}')
JOURNAL_SIZE=$(grep "^Journal size:" "$OUTPUT_DIR/01_journal_info.txt" | awk '{print $3}' | tr -d 'M')
JOURNAL_SEQ=$(grep "^Journal sequence:" "$OUTPUT_DIR/01_journal_info.txt" | awk '{print $3}')
JOURNAL_START=$(grep "^Journal start:" "$OUTPUT_DIR/01_journal_info.txt" | awk '{print $3}')

echo "  Journal inode: $JOURNAL_INODE"
echo "  Journal blocks: $JOURNAL_BLOCKS"
echo "  Journal size: ${JOURNAL_SIZE}M"
echo "  Journal sequence: $JOURNAL_SEQ"
echo "  Journal start: $JOURNAL_START"

if [ "$JOURNAL_START" = "0" ]; then
    echo "  ⚠ WARNING: Journal start is 0 (journal may be checkpointed)"
else
    echo "  ✓ Journal has active transactions"
fi
echo ""

echo "[3/6] Getting journal block locations"
# Get the actual block numbers where journal data lives
./debugfs/debugfs -R "stat <$JOURNAL_INODE>" "$SOURCE_IMG" 2>/dev/null > "$OUTPUT_DIR/02_journal_inode.txt"

# Extract blocks - handle EXTENTS format
FIRST_BLOCK=$(grep -E "(BLOCKS:|EXTENTS:)" "$OUTPUT_DIR/02_journal_inode.txt" -A 5 | \
    grep -oE '\([0-9]+\):?[0-9]+' | \
    grep -oE '[0-9]+$' | \
    head -1)

if [ -z "$FIRST_BLOCK" ]; then
    echo "  ERROR: Could not find journal blocks"
    cat "$OUTPUT_DIR/02_journal_inode.txt"
    exit 1
fi

echo "  First journal block: $FIRST_BLOCK"
echo "  Total journal blocks: $JOURNAL_BLOCKS"
echo ""

echo "[4/6] Reading journal blocks DIRECTLY with dd (O_DIRECT)"
echo "  This bypasses kernel cache - should not trigger checkpoint!"

# Use dd with direct I/O to read journal blocks
# iflag=direct uses O_DIRECT to bypass page cache
dd if="$SOURCE_IMG" \
   of="$OUTPUT_DIR/journal_blocks.raw" \
   bs="$BLOCK_SIZE" \
   skip="$FIRST_BLOCK" \
   count="$JOURNAL_BLOCKS" \
   iflag=direct \
   2>&1 | grep -E "bytes|copied" || true

echo "  ✓ Captured $JOURNAL_BLOCKS blocks directly from disk"
echo ""

echo "[5/6] Analyzing journal superblock from raw data"
# Read the journal superblock (first block of journal)
# It's a JBD2 superblock with known structure

# Extract key fields from journal superblock
# Offset 0: Magic number (0xC03B3998)
# Offset 4: Block type (3 or 4 for superblock)
# Offset 12: Sequence number
# Offset 16: Start block

if command -v xxd > /dev/null; then
    echo "  Journal superblock (first 128 bytes):"
    dd if="$OUTPUT_DIR/journal_blocks.raw" bs=128 count=1 2>/dev/null | xxd | head -10 | sed 's/^/    /'
    echo ""

    # Check magic number
    MAGIC=$(dd if="$OUTPUT_DIR/journal_blocks.raw" bs=4 count=1 2>/dev/null | xxd -p)
    echo "  Magic number: 0x$MAGIC"
    if [ "$MAGIC" = "98393bc0" ] || [ "$MAGIC" = "c03b3998" ]; then
        echo "  ✓ Valid JBD2 magic number"
    else
        echo "  ⚠ WARNING: Invalid magic number (should be 0xc03b3998)"
    fi
fi
echo ""

echo "[6/6] Checking journal state AFTER direct read"
# Check if journal is still intact after our direct read
SEQ_AFTER=$(./misc/dumpe2fs "$SOURCE_IMG" 2>/dev/null | grep "^Journal sequence:" | awk '{print $3}')
START_AFTER=$(./misc/dumpe2fs "$SOURCE_IMG" 2>/dev/null | grep "^Journal start:" | awk '{print $3}')

echo "  Sequence (before → after): $JOURNAL_SEQ → $SEQ_AFTER"
echo "  Start (before → after): $JOURNAL_START → $START_AFTER"

if [ "$JOURNAL_START" != "0" ] && [ "$START_AFTER" = "0" ]; then
    echo "  ⚠ Journal was checkpointed during our read!"
elif [ "$JOURNAL_START" = "0" ] && [ "$START_AFTER" = "0" ]; then
    echo "  ⚠ Journal was already checkpointed"
elif [ "$START_AFTER" != "0" ]; then
    echo "  ✓ Journal still has transactions after direct read"
fi
echo ""

# Save metadata
cat > "$OUTPUT_DIR/capture_metadata.txt" << EOF
# Direct Journal Capture Metadata
BLOCK_SIZE=$BLOCK_SIZE
JOURNAL_INODE=$JOURNAL_INODE
JOURNAL_BLOCKS=$JOURNAL_BLOCKS
JOURNAL_SIZE=$JOURNAL_SIZE
JOURNAL_SEQ=$JOURNAL_SEQ
JOURNAL_START=$JOURNAL_START
FIRST_BLOCK=$FIRST_BLOCK
CAPTURE_METHOD=direct_dd
EOF

echo "=================================================================="
echo "CAPTURE COMPLETE"
echo "=================================================================="
echo ""
echo "Captured journal using DIRECT BLOCK READS"
echo "  Method: dd with iflag=direct (bypasses kernel cache)"
echo "  Blocks captured: $JOURNAL_BLOCKS"
echo "  Sequence number: $JOURNAL_SEQ"
echo "  Start position: $JOURNAL_START"
echo ""
echo "Output files:"
echo "  - journal_blocks.raw ($JOURNAL_BLOCKS blocks of raw journal data)"
echo "  - 00_filesystem_info.txt (filesystem metadata)"
echo "  - 01_journal_info.txt (journal parameters)"
echo "  - 02_journal_inode.txt (journal inode details)"
echo "  - capture_metadata.txt (machine-readable metadata)"
echo ""

if [ "$JOURNAL_START" != "0" ]; then
    echo "✓ SUCCESS: Captured journal with active transactions!"
else
    echo "⚠ WARNING: Journal appears checkpointed (empty)"
    echo "  This might mean checkpoint happened BEFORE capture, not during"
fi
echo ""
