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

SEQ_BEFORE=$($E2FSPROGS_DIR/misc/dumpe2fs /dev/loop30 2>/dev/null | grep "Journal sequence:" | awk '{print $3}')
START_BEFORE=$($E2FSPROGS_DIR/misc/dumpe2fs /dev/loop30 2>/dev/null | grep "Journal start:" | awk '{print $3}')
echo "  Sequence: $SEQ_BEFORE"
echo "  Start: $START_BEFORE"
echo ""

echo -e "${CYAN}[3/5] Creating file1.txt${NC}"
echo "Hello from external journal test - file1.txt content" > /tmp/test_ext_journal/file1.txt
echo -e "${GREEN}✓${NC} file1.txt created"
echo ""

echo -e "${CYAN}[4/5] Check journal state AFTER file creation (immediate)${NC}"
JOURNAL_HASH_AFTER=$(md5sum journal.img | awk '{print $1}')
JOURNAL_SIZE_AFTER=$(stat -c %s journal.img)
echo "  Journal MD5: ${JOURNAL_HASH_AFTER:0:16}..."
echo "  Journal size: $JOURNAL_SIZE_AFTER bytes"

if [ "$JOURNAL_HASH_BEFORE" != "$JOURNAL_HASH_AFTER" ]; then
    echo -e "  ${GREEN}✓✓✓ Journal has CHANGED! (data was written)${NC}"
else
    echo -e "  ${YELLOW}⚠ Journal unchanged${NC}"
fi

SEQ_AFTER=$($E2FSPROGS_DIR/misc/dumpe2fs /dev/loop30 2>/dev/null | grep "Journal sequence:" | awk '{print $3}')
START_AFTER=$($E2FSPROGS_DIR/misc/dumpe2fs /dev/loop30 2>/dev/null | grep "Journal start:" | awk '{print $3}')
echo "  Sequence: $SEQ_BEFORE → $SEQ_AFTER"
echo "  Start: $START_BEFORE → $START_AFTER"

if [ "$START_AFTER" != "0" ]; then
    echo -e "  ${GREEN}✓✓✓ Journal NOT checkpointed! (Start=$START_AFTER)${NC}"
else
    echo -e "  ${RED}⚠ Journal checkpointed (Start=0)${NC}"
fi
echo ""

echo -e "${CYAN}[5/5] Wait 2 seconds and check persistence${NC}"
sleep 2
SEQ_2S=$($E2FSPROGS_DIR/misc/dumpe2fs /dev/loop30 2>/dev/null | grep "Journal sequence:" | awk '{print $3}')
START_2S=$($E2FSPROGS_DIR/misc/dumpe2fs /dev/loop30 2>/dev/null | grep "Journal start:" | awk '{print $3}')
JOURNAL_HASH_2S=$(md5sum journal.img | awk '{print $1}')

echo "  Sequence: $SEQ_AFTER → $SEQ_2S"
echo "  Start: $START_AFTER → $START_2S"
echo "  Journal MD5: ${JOURNAL_HASH_2S:0:16}..."

if [ "$START_2S" != "0" ] && [ "$JOURNAL_HASH_2S" = "$JOURNAL_HASH_AFTER" ]; then
    echo -e "  ${GREEN}✓✓✓ Journal PERSISTS after 2 seconds!${NC}"
elif [ "$START_2S" = "0" ]; then
    echo -e "  ${RED}⚠ Journal checkpointed within 2 seconds${NC}"
else
    echo -e "  ${YELLOW}⚠ Journal changed (commit happened)${NC}"
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

echo -e "${BOLD}${YELLOW}PHASE 5: CLEANUP AND ANALYSIS${NC}"
echo ""

umount /tmp/test_ext_journal
losetup -d /dev/loop30
losetup -d /dev/loop31

echo -e "${BOLD}${CYAN}===================================================================="
echo "RESULTS"
echo "====================================================================${NC}"
echo ""

if [ "$JOURNAL_HASH_BEFORE" != "$JOURNAL_HASH_AFTER" ]; then
    echo -e "${GREEN}✓ SUCCESS: External journal captured file changes!${NC}"
    echo ""
    echo "Key findings:"
    echo "  1. Journal.img changes when file is created"
    echo "  2. We can copy journal.img independently"
    echo "  3. No filesystem operations needed to read journal"
    echo ""
    echo "This means external journal SOLVES the checkpoint timing issue!"
    echo ""
    echo "Next steps:"
    echo "  - Implement continuous monitoring of journal.img"
    echo "  - Copy journal.img when it changes (md5sum detection)"
    echo "  - Apply captured journal to replica"
else
    echo -e "${RED}✗ FAILED: External journal didn't capture changes${NC}"
    echo ""
    echo "Possible reasons:"
    echo "  - Journal still checkpoints immediately"
    echo "  - data=journal mode not working with external journal"
    echo "  - Need different mount options"
fi
echo ""

rm -rf /tmp/test_external_journal

echo "Test complete!"
echo ""
