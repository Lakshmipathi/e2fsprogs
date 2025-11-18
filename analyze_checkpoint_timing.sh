#!/bin/bash
#
# analyze_checkpoint_timing.sh - Analyze when journal checkpoints happen
#
# This creates a test filesystem, writes a file, and monitors journal state
# to understand the checkpoint timing issue.
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BOLD}${CYAN}===================================================================="
echo "JOURNAL CHECKPOINT TIMING ANALYSIS"
echo "====================================================================${NC}"
echo ""

# Cleanup
cleanup() {
    umount /tmp/test_mnt 2>/dev/null || true
    losetup -d /dev/loop30 2>/dev/null || true
    rm -rf /tmp/test_checkpoint_analysis
}
cleanup

mkdir -p /tmp/test_checkpoint_analysis
cd /tmp/test_checkpoint_analysis

echo -e "${YELLOW}Step 1: Create filesystem${NC}"
dd if=/dev/zero of=test.img bs=1M count=50 2>/dev/null
./misc/mke2fs -t ext4 -F test.img >/dev/null 2>&1
echo -e "${GREEN}✓${NC} Filesystem created"
echo ""

echo -e "${YELLOW}Step 2: Check initial journal state${NC}"
INIT_SEQ=$(./misc/dumpe2fs test.img 2>/dev/null | grep "Journal sequence:" | awk '{print $3}')
INIT_START=$(./misc/dumpe2fs test.img 2>/dev/null | grep "Journal start:" | awk '{print $3}')
echo "  Initial sequence: $INIT_SEQ"
echo "  Initial start: $INIT_START"
echo ""

echo -e "${YELLOW}Step 3: Mount with data=journal,commit=9999${NC}"
losetup /dev/loop30 test.img
mkdir -p /tmp/test_mnt
mount -o data=journal,barrier=0,commit=9999 /dev/loop30 /tmp/test_mnt
echo -e "${GREEN}✓${NC} Mounted"
echo ""

echo -e "${YELLOW}Step 4: Create single file (file1.txt)${NC}"
echo "Test content for file1" > /tmp/test_mnt/file1.txt
WRITE_TIME=$(date +%s)
echo -e "${GREEN}✓${NC} file1.txt created at timestamp: $WRITE_TIME"
echo ""

echo -e "${YELLOW}Step 5: Monitor journal state over time${NC}"
echo ""

# Function to check journal state
check_journal() {
    local label="$1"
    local elapsed="$2"

    SEQ=$(./misc/dumpe2fs test.img 2>/dev/null | grep "Journal sequence:" | awk '{print $3}')
    START=$(./misc/dumpe2fs test.img 2>/dev/null | grep "Journal start:" | awk '{print $3}')

    # Count transaction blocks in logdump
    LOGDUMP=$(./debugfs/debugfs -R "logdump -a" test.img 2>/dev/null)
    DESC_COUNT=$(echo "$LOGDUMP" | grep -c "type 1 (descriptor block)" || echo "0")
    COMMIT_COUNT=$(echo "$LOGDUMP" | grep -c "type 2 (commit block)" || echo "0")

    echo -e "${CYAN}[$label] (t=${elapsed}s)${NC}"
    echo "  Sequence: $SEQ"
    echo "  Start: $START (0=checkpointed/empty)"
    echo "  Descriptor blocks: $DESC_COUNT"
    echo "  Commit blocks: $COMMIT_COUNT"

    if [ "$START" = "0" ]; then
        echo -e "  ${RED}⚠ Journal is CHECKPOINTED (empty)${NC}"
    else
        echo -e "  ${GREEN}✓ Journal has transactions${NC}"
    fi

    # Show first few lines of logdump
    echo "  First 5 lines of logdump:"
    echo "$LOGDUMP" | head -5 | sed 's/^/    /'
    echo ""
}

# Check immediately
check_journal "IMMEDIATE" "0"

# Check at 0.5s
sleep 0.5
check_journal "0.5 seconds" "0.5"

# Check at 1s
sleep 0.5
check_journal "1 second" "1"

# Check at 2s
sleep 1
check_journal "2 seconds" "2"

# Check at 3s
sleep 1
check_journal "3 seconds" "3"

# Check at 5s
sleep 2
check_journal "5 seconds" "5"

# Check at 10s
sleep 5
check_journal "10 seconds" "10"

echo -e "${YELLOW}Step 6: Try capturing with our replication script${NC}"
./journal_replicate_capture.sh test.img capture_test > capture.log 2>&1 || true
TRANS_FOUND=$(grep "Transactions found:" capture.log | awk '{print $3}' || echo "0")
echo "  Transactions captured: $TRANS_FOUND"
if [ "$TRANS_FOUND" = "0" ]; then
    echo -e "  ${RED}⚠ No transactions captured${NC}"
else
    echo -e "  ${GREEN}✓ Successfully captured transactions${NC}"
fi
echo ""

echo -e "${YELLOW}Step 7: Check /proc/mounts for actual mount options${NC}"
grep "/tmp/test_mnt" /proc/mounts || echo "  Not found in /proc/mounts"
echo ""

echo -e "${YELLOW}Step 8: Check kernel journal commit behavior${NC}"
# Try to read journal commit interval from sysfs/debugfs if available
if [ -d /sys/fs/ext4/loop30 ]; then
    echo "  Found ext4 sysfs entries:"
    ls -la /sys/fs/ext4/loop30/ | sed 's/^/    /'
fi
echo ""

echo -e "${YELLOW}Step 9: Cleanup${NC}"
cleanup
echo -e "${GREEN}✓${NC} Done"
echo ""

echo -e "${BOLD}${CYAN}ANALYSIS:${NC}"
echo "This test shows EXACTLY when ext4 checkpoints the journal."
echo ""
echo "Key findings:"
echo "  - If 'Start: 0' appears immediately → Checkpoint happens < 0.5s"
echo "  - If 'Start: 0' appears at t=1s → Checkpoint happens between 0.5-1s"
echo "  - If 'Start: 0' appears at t=2s → Checkpoint happens between 1-2s"
echo "  - If 'Start: 0' never appears → commit=9999 is working"
echo ""
echo "If checkpoint happens quickly, we need to:"
echo "  1. Capture FASTER (< 0.5s interval)"
echo "  2. Use dd with iflag=direct to bypass kernel cache"
echo "  3. Use a kernel module to intercept journal writes"
echo "  4. Accept limitation and use different approach"
echo ""
