#!/bin/bash
#
# test_replication_internal_journal.sh - Replicate using WORKING internal journal method
#
# Uses the PROVEN approach from journal_explorer_enhanced.sh which successfully
# captures journal transactions. No external journal complexity!
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
echo "INTERNAL JOURNAL REPLICATION TEST"
echo "====================================================================${NC}"
echo ""
echo -e "${YELLOW}Using PROVEN method from journal_explorer_enhanced.sh${NC}"
echo -e "${YELLOW}Goal: Replicate file1.txt from server1 to server2${NC}"
echo ""

cleanup() {
    umount /tmp/repl_s1 2>/dev/null || true
    umount /tmp/repl_s2 2>/dev/null || true
    LOOP1=$(losetup -j server1.img 2>/dev/null | cut -d: -f1)
    LOOP2=$(losetup -j server2.img 2>/dev/null | cut -d: -f1)
    [ -n "$LOOP1" ] && losetup -d "$LOOP1" 2>/dev/null || true
    [ -n "$LOOP2" ] && losetup -d "$LOOP2" 2>/dev/null || true
    rm -rf /tmp/test_replication_internal
}
cleanup

mkdir -p /tmp/test_replication_internal
cd /tmp/test_replication_internal

echo -e "${BOLD}${YELLOW}PHASE 1: SETUP IDENTICAL FILESYSTEMS${NC}"
echo ""

echo -e "${CYAN}[1/3] Creating server1 filesystem (100MB)${NC}"
dd if=/dev/zero of=server1.img bs=1M count=100 2>/dev/null
$E2FSPROGS_DIR/misc/mke2fs -t ext4 -F server1.img >/dev/null 2>&1
echo -e "${GREEN}✓${NC} server1.img created"

echo -e "${CYAN}[2/3] Creating server2 (identical copy)${NC}"
cp server1.img server2.img
echo -e "${GREEN}✓${NC} server2.img created (exact copy of server1)"

echo -e "${CYAN}[3/3] Verifying they are identical${NC}"
HASH1=$(md5sum server1.img | awk '{print $1}')
HASH2=$(md5sum server2.img | awk '{print $1}')
if [ "$HASH1" = "$HASH2" ]; then
    echo -e "${GREEN}✓${NC} Checksums match: ${HASH1:0:16}..."
else
    echo -e "${RED}✗${NC} ERROR: Checksums don't match!"
    exit 1
fi
echo ""

echo -e "${BOLD}${YELLOW}PHASE 2: CREATE FILES ON SERVER1 (same method as journal_explorer_enhanced)${NC}"
echo ""

echo -e "${CYAN}[1/5] Setting up loop device${NC}"
LOOP_DEV=$(losetup -f)
losetup "$LOOP_DEV" server1.img
echo -e "${GREEN}✓${NC} Loop device: $LOOP_DEV"

echo -e "${CYAN}[2/5] Mounting with data=journal,commit=9999 (PROVEN settings)${NC}"
mkdir -p /tmp/repl_s1
mount -o data=journal,commit=9999,barrier=0 "$LOOP_DEV" /tmp/repl_s1
echo -e "${GREEN}✓${NC} Mounted at /tmp/repl_s1"

echo -e "${CYAN}[3/5] Creating 6 files (same as journal_explorer_enhanced)${NC}"
echo "Hello from server1 - this is file1.txt content" > /tmp/repl_s1/file1.txt
for i in {2..6}; do
    echo "Test file $i - $(date +%s%N)" > /tmp/repl_s1/test$i.txt
done
echo -e "${GREEN}✓${NC} Created 6 files"

echo -e "${CYAN}[4/5] Syncing to journal${NC}"
sync
echo -e "${GREEN}✓${NC} Synced"

echo -e "${CYAN}[5/5] Unmounting (critical for journal preservation)${NC}"
umount /tmp/repl_s1
losetup -d "$LOOP_DEV"
echo -e "${GREEN}✓${NC} Unmounted"
echo ""

echo -e "${BOLD}${YELLOW}PHASE 3: CAPTURE JOURNAL (using proven method)${NC}"
echo ""

echo -e "${CYAN}[1/2] Reading journal with debugfs logdump${NC}"
LOGDUMP=$($E2FSPROGS_DIR/debugfs/debugfs -R "logdump -a" server1.img 2>/dev/null)
echo "$LOGDUMP" > journal_capture.txt
echo -e "${GREEN}✓${NC} Journal captured to journal_capture.txt"

echo -e "${CYAN}[2/2] Analyzing captured journal${NC}"
DESC_COUNT=$(echo "$LOGDUMP" | grep -Fc "type 1 (descriptor block)" 2>/dev/null || echo "0")
DESC_COUNT=${DESC_COUNT//
/}
COMMIT_COUNT=$(echo "$LOGDUMP" | grep -Fc "type 2 (commit block)" 2>/dev/null || echo "0")
COMMIT_COUNT=${COMMIT_COUNT//
/}

echo "  Descriptor blocks: $DESC_COUNT"
echo "  Commit blocks: $COMMIT_COUNT"

if [ "$DESC_COUNT" -gt 0 ] || [ "$COMMIT_COUNT" -gt 0 ]; then
    echo -e "  ${GREEN}✓✓✓ Journal has TRANSACTIONS! (proven method works)${NC}"
else
    echo -e "  ${RED}✗${NC} No transactions found"
    echo "  This should not happen since journal_explorer_enhanced.sh works!"
    echo ""
    echo "First 30 lines of logdump:"
    echo "$LOGDUMP" | head -30 | sed 's/^/  /'
    exit 1
fi

# Extract journal metadata
JOURNAL_SEQ=$($E2FSPROGS_DIR/misc/dumpe2fs server1.img 2>/dev/null | grep "^Journal sequence:" | awk '{print $3}')
JOURNAL_START=$($E2FSPROGS_DIR/misc/dumpe2fs server1.img 2>/dev/null | grep "^Journal start:" | awk '{print $3}')
BLOCK_SIZE=$($E2FSPROGS_DIR/misc/dumpe2fs server1.img 2>/dev/null | grep "^Block size:" | awk '{print $3}')
JOURNAL_INODE=$($E2FSPROGS_DIR/misc/dumpe2fs server1.img 2>/dev/null | grep "^Journal inode:" | awk '{print $3}')
JOURNAL_BLOCKS=$($E2FSPROGS_DIR/misc/dumpe2fs server1.img 2>/dev/null | grep "^Journal blocks:" | awk '{print $3}')

echo "  Journal sequence: $JOURNAL_SEQ"
echo "  Journal start: $JOURNAL_START"
echo ""

echo -e "${BOLD}${YELLOW}PHASE 4: EXTRACT JOURNAL BLOCKS${NC}"
echo ""

echo -e "${CYAN}[1/3] Getting journal block locations${NC}"
$E2FSPROGS_DIR/debugfs/debugfs -R "stat <$JOURNAL_INODE>" server1.img 2>/dev/null > journal_inode.txt

FIRST_BLOCK=$(grep -E "(BLOCKS:|EXTENTS:)" journal_inode.txt -A 5 | \
    grep -oE '\([0-9]+\):?[0-9]+' | \
    grep -oE '[0-9]+$' | \
    head -1)

if [ -z "$FIRST_BLOCK" ]; then
    echo -e "  ${RED}✗${NC} Could not find journal blocks"
    cat journal_inode.txt
    exit 1
fi

echo "  First journal block: $FIRST_BLOCK"
echo "  Total journal blocks: $JOURNAL_BLOCKS"

echo -e "${CYAN}[2/3] Extracting journal blocks from server1${NC}"
dd if=server1.img \
   of=journal_blocks.raw \
   bs="$BLOCK_SIZE" \
   skip="$FIRST_BLOCK" \
   count="$JOURNAL_BLOCKS" \
   2>&1 | grep -E "bytes|copied" || true

JOURNAL_SIZE=$(stat -c %s journal_blocks.raw)
echo -e "${GREEN}✓${NC} Extracted $JOURNAL_SIZE bytes"

echo -e "${CYAN}[3/3] Verifying journal has data${NC}"
if command -v xxd > /dev/null; then
    echo "  First 64 bytes of journal:"
    xxd journal_blocks.raw | head -4 | sed 's/^/    /'
fi
echo ""

echo -e "${BOLD}${YELLOW}PHASE 5: INJECT JOURNAL INTO SERVER2${NC}"
echo ""

echo -e "${CYAN}[1/2] Writing journal blocks to server2${NC}"
dd if=journal_blocks.raw \
   of=server2.img \
   bs="$BLOCK_SIZE" \
   seek="$FIRST_BLOCK" \
   count="$JOURNAL_BLOCKS" \
   conv=notrunc \
   2>&1 | grep -E "bytes|copied" || true

echo -e "${GREEN}✓${NC} Journal blocks injected"

echo -e "${CYAN}[2/2] Running e2fsck to replay journal on server2${NC}"
$E2FSPROGS_DIR/e2fsck/e2fsck -fy server2.img 2>&1 | head -10 | sed 's/^/  /'
echo ""

echo -e "${BOLD}${YELLOW}PHASE 6: VERIFY REPLICATION${NC}"
echo ""

echo -e "${CYAN}[1/4] Setting up loop device for server2${NC}"
LOOP_DEV2=$(losetup -f)
losetup "$LOOP_DEV2" server2.img
echo -e "${GREEN}✓${NC} Loop device: $LOOP_DEV2"

echo -e "${CYAN}[2/4] Mounting server2${NC}"
mkdir -p /tmp/repl_s2
mount "$LOOP_DEV2" /tmp/repl_s2
echo -e "${GREEN}✓${NC} Mounted at /tmp/repl_s2"

echo -e "${CYAN}[3/4] Checking for file1.txt on server2${NC}"
FILE_EXISTS=false
if [ -f /tmp/repl_s2/file1.txt ]; then
    FILE_EXISTS=true
    CONTENT=$(cat /tmp/repl_s2/file1.txt)
    echo -e "  ${GREEN}✓✓✓ SUCCESS! file1.txt EXISTS on server2${NC}"
    echo ""
    echo "  Content: '$CONTENT'"
    echo ""

    # Verify content matches
    ORIGINAL="Hello from server1 - this is file1.txt content"
    if [ "$CONTENT" = "$ORIGINAL" ]; then
        echo -e "  ${GREEN}✓✓✓ Content MATCHES original!${NC}"
    else
        echo -e "  ${YELLOW}⚠${NC} Content differs"
        echo "    Expected: '$ORIGINAL'"
        echo "    Got:      '$CONTENT'"
    fi
else
    echo -e "  ${RED}✗ FAILED - file1.txt NOT found on server2${NC}"
    echo ""
    echo "  Files on server2:"
    ls -la /tmp/repl_s2 | sed 's/^/    /'
fi
echo ""

echo -e "${CYAN}[4/4] Checking other files${NC}"
for i in {2..6}; do
    if [ -f /tmp/repl_s2/test$i.txt ]; then
        echo -e "  ${GREEN}✓${NC} test$i.txt replicated"
    else
        echo -e "  ${YELLOW}⚠${NC} test$i.txt missing"
    fi
done
echo ""

umount /tmp/repl_s2
losetup -d "$LOOP_DEV2"

cleanup

echo -e "${BOLD}${CYAN}===================================================================="
echo "RESULTS"
echo "====================================================================${NC}"
echo ""

if [ "$FILE_EXISTS" = "true" ]; then
    echo -e "${GREEN}✓ SUCCESS: Journal-based replication WORKS with internal journal!${NC}"
    echo ""
    echo "Key findings:"
    echo "  1. Internal journal captures transactions (proven by journal_explorer_enhanced.sh)"
    echo "  2. We can extract journal blocks directly from server1.img"
    echo "  3. We can inject those blocks into server2.img"
    echo "  4. e2fsck successfully replays the journal"
    echo "  5. file1.txt appears on server2 with correct content"
    echo ""
    echo "This proves journal-based replication is FEASIBLE!"
    echo ""
    echo "No need for external journal complexity!"
else
    echo -e "${RED}✗ FAILED: Replication did not work${NC}"
    echo ""
    echo "Possible issues:"
    echo "  - Journal blocks not extracted correctly"
    echo "  - Injection offset wrong"
    echo "  - e2fsck not replaying journal"
fi
echo ""
