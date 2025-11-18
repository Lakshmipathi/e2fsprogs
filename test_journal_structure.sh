#!/bin/bash
#
# test_journal_structure.sh - Test if we can read journal structure
#

set -e

E2FSPROGS_DIR=$(pwd)

echo "===================================================================="
echo "TESTING JOURNAL STRUCTURE EXTRACTION"
echo "===================================================================="
echo ""

cleanup() {
    rm -rf /tmp/test_journal_struct
}
cleanup

mkdir -p /tmp/test_journal_struct
cd /tmp/test_journal_struct

echo "Step 1: Create filesystem"
dd if=/dev/zero of=test.img bs=1M count=50 2>/dev/null
$E2FSPROGS_DIR/misc/mke2fs -t ext4 -F test.img >/dev/null 2>&1
echo "✓ Created"
echo ""

echo "Step 2: Get journal info"
$E2FSPROGS_DIR/misc/dumpe2fs test.img 2>/dev/null | grep -A 10 "^Journal" > journal_info.txt
cat journal_info.txt
echo ""

echo "Step 3: Extract journal inode"
JOURNAL_INODE=$(grep "^Journal inode:" journal_info.txt | awk '{print $3}')
echo "Journal inode: $JOURNAL_INODE"
echo ""

echo "Step 4: Get journal inode details"
$E2FSPROGS_DIR/debugfs/debugfs -R "stat <$JOURNAL_INODE>" test.img 2>/dev/null > journal_inode.txt
cat journal_inode.txt
echo ""

echo "Step 5: Extract journal blocks"
echo "Looking for EXTENTS: or BLOCKS:"
grep -E "(EXTENTS:|BLOCKS:)" journal_inode.txt -A 10

echo ""
echo "Step 6: Parse extent/block numbers"
FIRST_BLOCK=$(grep -E "(BLOCKS:|EXTENTS:)" journal_inode.txt -A 5 | \
    grep -oE '\([0-9]+\):?[0-9]+' | \
    grep -oE '[0-9]+$' | \
    head -1)

if [ -z "$FIRST_BLOCK" ]; then
    echo "✗ FAILED to extract first block"
    echo "Full extent line:"
    grep -E "(EXTENTS:|BLOCKS:)" journal_inode.txt -A 5
else
    echo "✓ First journal block: $FIRST_BLOCK"
fi

echo ""
echo "Step 7: Try alternative parsing"
echo "Method 1: Look for physical block numbers"
grep -E "^\(0\):" journal_inode.txt || echo "No (0): line found"

echo ""
echo "Method 2: Look for any numbers after colon"
grep -E ":" journal_inode.txt | grep -oE '[0-9]+' | head -5

cleanup

echo ""
echo "===================================================================="
echo "If FIRST_BLOCK is empty, journal block extraction is broken"
echo "This would explain why capture fails with 'Could not find journal blocks'"
echo "===================================================================="
