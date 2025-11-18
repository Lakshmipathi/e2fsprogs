#!/bin/bash
#
# test_single_file_replication.sh - Focused test for single file replication
#
# This script focuses on replicating JUST ONE FILE to understand the journal behavior
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BOLD}${CYAN}==================================================================="
echo "SINGLE FILE REPLICATION TEST"
echo "===================================================================${NC}"
echo ""

# Cleanup
cleanup() {
    umount /tmp/test_mnt 2>/dev/null || true
    losetup -d /dev/loop30 2>/dev/null || true
    rm -rf /tmp/test_repl
}
cleanup

mkdir -p /tmp/test_repl
cd /tmp/test_repl

echo -e "${YELLOW}Step 1: Create filesystem${NC}"
dd if=/dev/zero of=test.img bs=1M count=50 2>/dev/null
./misc/mke2fs -t ext4 -F test.img >/dev/null 2>&1
echo -e "${GREEN}✓${NC} Filesystem created"
echo ""

echo -e "${YELLOW}Step 2: Check initial journal state${NC}"
echo "  Journal before mounting:"
./debugfs/debugfs -R "logdump -a" test.img 2>/dev/null | head -3
echo ""

echo -e "${YELLOW}Step 3: Mount with data=journal,commit=9999${NC}"
losetup /dev/loop30 test.img
mkdir -p /tmp/test_mnt
mount -o data=journal,barrier=0,commit=9999 /dev/loop30 /tmp/test_mnt
echo -e "${GREEN}✓${NC} Mounted"
echo ""

echo -e "${YELLOW}Step 4: Create SINGLE file (file1.txt)${NC}"
echo "Test content for file1" > /tmp/test_mnt/file1.txt
echo -e "${GREEN}✓${NC} file1.txt created"
ls -la /tmp/test_mnt/file1.txt
echo ""

echo -e "${YELLOW}Step 5: Check journal IMMEDIATELY (0 seconds)${NC}"
echo "  Journal state (t=0s):"
./debugfs/debugfs -R "logdump -a" test.img 2>/dev/null | head -10
echo ""

echo -e "${YELLOW}Step 6: Wait 1 second, check again${NC}"
sleep 1
echo "  Journal state (t=1s):"
./debugfs/debugfs -R "logdump -a" test.img 2>/dev/null | head -10
echo ""

echo -e "${YELLOW}Step 7: Wait 2 more seconds, check again${NC}"
sleep 2
echo "  Journal state (t=3s total):"
./debugfs/debugfs -R "logdump -a" test.img 2>/dev/null | head -10
echo ""

echo -e "${YELLOW}Step 8: Check journal sequence number${NC}"
SEQ=$(./misc/dumpe2fs test.img 2>/dev/null | grep "Journal sequence:" | awk '{print $3}')
START=$(./misc/dumpe2fs test.img 2>/dev/null | grep "Journal start:" | awk '{print $3}')
echo "  Sequence: $SEQ"
echo "  Start: $START"
echo "  (Start=0 means journal is empty/checkpointed)"
echo ""

echo -e "${YELLOW}Step 9: Try capturing with our script${NC}"
./journal_replicate_capture.sh test.img capture_test > capture.log 2>&1
grep "Transactions found" capture.log || echo "  No transaction info found"
grep "WARNING" capture.log || echo "  No warnings"
echo ""

echo -e "${YELLOW}Step 10: Cleanup${NC}"
cleanup
echo -e "${GREEN}✓${NC} Done"
echo ""

echo -e "${BOLD}${CYAN}ANALYSIS:${NC}"
echo "If 'Journal start: 0' → Journal was checkpointed (empty)"
echo "If we see 'No magic number at block 1' → Journal has no transactions"
echo "This means ext4 checkpointed before we could capture!"
echo ""
echo "Possible solutions:"
echo "  1. Capture FASTER (< 1 second after file creation)"
echo "  2. Read journal blocks directly with dd (bypass cache)"
echo "  3. Use kernel module to intercept journal writes"
echo "  4. Accept limitation and use different approach"
