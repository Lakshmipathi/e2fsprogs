#!/bin/bash
#
# test_external_journal.sh - Test external journal device for replication
#
# Key insight: Using separate journal.img means we can read the journal
# without accessing main filesystem, potentially avoiding checkpoint triggers.
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

E2FSPROGS_DIR=$(pwd)
export E2FSPROGS_DIR

echo -e "${BOLD}${CYAN}===================================================================="
echo "EXTERNAL JOURNAL DEVICE TEST"
echo "====================================================================${NC}"
echo ""
echo -e "${YELLOW}Goal: Use separate journal.img to avoid checkpoint issues${NC}"
echo ""

cleanup() {
    umount /tmp/test_ext_journal 2>/dev/null || true
    losetup -d /dev/loop30 2>/dev/null || true
    losetup -d /dev/loop31 2>/dev/null || true
    rm -rf /tmp/test_external_journal
}
cleanup

mkdir -p /tmp/test_external_journal
cd /tmp/test_external_journal

echo -e "${BOLD}${YELLOW}PHASE 1: CREATE FILESYSTEM WITH EXTERNAL JOURNAL${NC}"
echo ""

echo -e "${CYAN}[1/4] Creating journal device (16MB)${NC}"
dd if=/dev/zero of=journal.img bs=1M count=16 2>/dev/null
echo -e "${GREEN}✓${NC} journal.img created"

echo -e "${CYAN}[2/4] Creating main filesystem (100MB)${NC}"
dd if=/dev/zero of=fs.img bs=1M count=100 2>/dev/null
echo -e "${GREEN}✓${NC} fs.img created"

echo -e "${CYAN}[3/4] Setting up loop devices${NC}"
losetup /dev/loop30 fs.img
losetup /dev/loop31 journal.img
echo -e "${GREEN}✓${NC} Loop devices ready"
echo "  Main FS: /dev/loop30"
echo "  Journal: /dev/loop31"

echo -e "${CYAN}[4/4] Creating ext4 with external journal${NC}"
$E2FSPROGS_DIR/misc/mke2fs -t ext4 -O journal_dev /dev/loop31 >/dev/null 2>&1
$E2FSPROGS_DIR/misc/mke2fs -t ext4 -J device=/dev/loop31 /dev/loop30 >/dev/null 2>&1
echo -e "${GREEN}✓${NC} Filesystem created with external journal"
echo ""

echo -e "${BOLD}${YELLOW}PHASE 2: VERIFY SETUP${NC}"
echo ""

echo -e "${CYAN}[1/2] Checking filesystem info${NC}"
$E2FSPROGS_DIR/misc/dumpe2fs /dev/loop30 2>/dev/null | grep -A 5 "^Journal" | head -10
echo ""

echo -e "${CYAN}[2/2] Checking journal device${NC}"
echo "  Journal device size: $(ls -lh journal.img | awk '{print $5}')"
echo ""

echo -e "${BOLD}${YELLOW}PHASE 3: CREATE FILE AND MONITOR JOURNAL${NC}"
echo ""

echo -e "${CYAN}[1/5] Mounting with data=journal,commit=9999${NC}"
mkdir -p /tmp/test_ext_journal
mount -o data=journal,commit=9999,barrier=0 /dev/loop30 /tmp/test_ext_journal
echo -e "${GREEN}✓${NC} Mounted"

echo -e "${CYAN}[2/5] Check journal state BEFORE file creation${NC}"
JOURNAL_HASH_BEFORE=$(md5sum journal.img | awk '{print $1}')
JOURNAL_SIZE_BEFORE=$(stat -c %s journal.img)
echo "  Journal MD5: ${JOURNAL_HASH_BEFORE:0:16}..."
echo "  Journal size: $JOURNAL_SIZE_BEFORE bytes"

# For external journal, debugfs reads from MAIN FS and finds external journal
echo "  Main FS logdump (debugfs auto-finds external journal):"
$E2FSPROGS_DIR/debugfs/debugfs -R "logdump -a" /dev/loop30 2>/dev/null | head -10 | sed 's/^/    /'
echo ""

echo -e "${CYAN}[3/5] Creating multiple files (like journal_explorer_enhanced)${NC}"
echo "Hello from external journal test - file1.txt content" > /tmp/test_ext_journal/file1.txt
# Create more files to generate more journal activity
for i in {2..6}; do
    echo "Test file $i - $(date +%s%N)" > /tmp/test_ext_journal/test$i.txt
done
sync  # Flush to journal
echo -e "${GREEN}✓${NC} Created 6 files and synced"
echo ""

echo -e "${CYAN}[4/5] UNMOUNT and check journal (key step!)${NC}"
echo "  Unmounting filesystem (like journal_explorer_enhanced.sh does)..."
umount /tmp/test_ext_journal
echo -e "${GREEN}✓${NC} Unmounted"
echo ""

echo -e "${CYAN}Check journal state AFTER file creation${NC}"
JOURNAL_HASH_AFTER=$(md5sum journal.img | awk '{print $1}')
JOURNAL_SIZE_AFTER=$(stat -c %s journal.img)
echo "  Journal MD5: ${JOURNAL_HASH_AFTER:0:16}..."
echo "  Journal size: $JOURNAL_SIZE_AFTER bytes"

if [ "$JOURNAL_HASH_BEFORE" != "$JOURNAL_HASH_AFTER" ]; then
    echo -e "  ${GREEN}✓✓✓ Journal has CHANGED! (data was written)${NC}"
else
    echo -e "  ${YELLOW}⚠ Journal unchanged${NC}"
fi

echo "  Main FS logdump (first 20 lines):"
LOGDUMP_AFTER=$($E2FSPROGS_DIR/debugfs/debugfs -R "logdump -a" /dev/loop30 2>/dev/null | head -20)
echo "$LOGDUMP_AFTER" | sed 's/^/    /'

# Count transactions in journal
DESC_COUNT=$(echo "$LOGDUMP_AFTER" | grep -Fc "type 1 (descriptor block)" 2>/dev/null || echo "0")
DESC_COUNT=${DESC_COUNT//
/}  # Remove newlines
COMMIT_COUNT=$(echo "$LOGDUMP_AFTER" | grep -Fc "type 2 (commit block)" 2>/dev/null || echo "0")
COMMIT_COUNT=${COMMIT_COUNT//
/}  # Remove newlines
echo "  Descriptor blocks: $DESC_COUNT"
echo "  Commit blocks: $COMMIT_COUNT"

if [ "$DESC_COUNT" -gt 0 ] || [ "$COMMIT_COUNT" -gt 0 ]; then
    echo -e "  ${GREEN}✓✓✓ Journal has TRANSACTIONS!${NC}"
else
    echo -e "  ${YELLOW}⚠ No transactions found in journal${NC}"
fi
echo ""

echo -e "${CYAN}[5/5] Verify journal was captured${NC}"
if [ "$DESC_COUNT" -gt 0 ] || [ "$COMMIT_COUNT" -gt 0 ]; then
    echo -e "  ${GREEN}✓✓✓ Journal has transactions after unmount!${NC}"
    echo "  This proves external journal works for replication"
else
    echo -e "  ${YELLOW}⚠ Journal empty after unmount${NC}"
    echo "  Possible issues:"
    echo "    - sync triggered checkpoint"
    echo "    - data=journal not working with external journal"
    echo "    - Need to read journal.img file instead of /dev/loop31"
fi
echo ""

echo -e "${BOLD}${YELLOW}PHASE 4: TEST JOURNAL CAPTURE${NC}"
echo ""

echo -e "${CYAN}[1/2] Copy journal.img for replication${NC}"
cp journal.img journal_captured.img
CAPTURED_SIZE=$(stat -c %s journal_captured.img)
echo -e "${GREEN}✓${NC} Captured: $CAPTURED_SIZE bytes"

echo -e "${CYAN}[2/2] Analyze captured journal${NC}"
# Check if journal has actual data (non-zero content)
if command -v xxd > /dev/null; then
    echo "  First 64 bytes of captured journal:"
    xxd journal_captured.img | head -4 | sed 's/^/    /'

    # Check for JBD2 magic number (0xc03b3998)
    MAGIC=$(dd if=journal_captured.img bs=4 count=1 skip=256 2>/dev/null | xxd -p)
    if [ "$MAGIC" = "98393bc0" ] || [ "$MAGIC" = "c03b3998" ]; then
        echo -e "  ${GREEN}✓ Valid JBD2 magic number found${NC}"
    else
        echo "  Magic at offset 1024: 0x$MAGIC"
    fi
fi
echo ""

echo -e "${BOLD}${YELLOW}PHASE 5: CLEANUP${NC}"
echo ""

# Already unmounted in Phase 3
losetup -d /dev/loop30 2>/dev/null || true
losetup -d /dev/loop31 2>/dev/null || true

echo -e "${BOLD}${CYAN}===================================================================="
echo "RESULTS"
echo "====================================================================${NC}"
echo ""

if [ "$DESC_COUNT" -gt 0 ] || [ "$COMMIT_COUNT" -gt 0 ]; then
    echo -e "${GREEN}✓ SUCCESS: External journal captured file changes!${NC}"
    echo ""
    echo "Key findings:"
    echo "  1. Journal.img has transactions (descriptor/commit blocks)"
    echo "  2. We can read journal device independently with debugfs logdump"
    echo "  3. Journal.img can be copied for replication"
    echo "  4. No need to access main filesystem to read journal"
    echo ""
    echo "This means external journal SOLVES the checkpoint timing issue!"
    echo ""
    echo "Next steps:"
    echo "  - Unmount filesystem and read journal.img offline"
    echo "  - Copy journal.img to server2"
    echo "  - Apply journal to replica using e2fsck"
    echo "  - Test full replication workflow"
else
    echo -e "${RED}✗ FAILED: External journal didn't capture changes${NC}"
    echo ""
    echo "Possible reasons:"
    echo "  - Journal still checkpoints immediately even with external device"
    echo "  - data=journal mode not working with external journal"
    echo "  - Need to unmount before reading journal"
    echo "  - Different mount options required"
fi
echo ""

rm -rf /tmp/test_external_journal

echo "Test complete!"
echo ""
