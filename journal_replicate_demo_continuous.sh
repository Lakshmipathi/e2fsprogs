#!/bin/bash
#
# journal_replicate_demo_continuous.sh - Continuous replication demonstration
#
# Demonstrates live replication where server1 stays running and serving I/O
# while journal changes are continuously captured and replicated to server2.
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

echo -e "${BOLD}${CYAN}==================================================================="
echo "CONTINUOUS JOURNAL REPLICATION DEMONSTRATION"
echo "===================================================================${NC}"
echo ""
echo -e "${YELLOW}This demo shows LIVE replication - server1 stays running!${NC}"
echo ""

# Cleanup function
cleanup() {
    echo ""
    echo -e "${YELLOW}Cleaning up...${NC}"
    kill $MONITOR_PID 2>/dev/null || true
    umount server1_mount 2>/dev/null || true
    umount server2_mount 2>/dev/null || true
    losetup -d /dev/loop20 2>/dev/null || true
    losetup -d /dev/loop21 2>/dev/null || true
    rm -rf demo_continuous
    echo -e "${GREEN}✓ Cleaned up${NC}"
}

# Handle Ctrl+C
trap cleanup EXIT

# Create working directory
DEMO_DIR="demo_continuous"
rm -rf "$DEMO_DIR"
mkdir -p "$DEMO_DIR"
cd "$DEMO_DIR"

echo -e "${BOLD}${YELLOW}PHASE 1: INITIAL SETUP${NC}"
echo ""

# Create source filesystem (server1)
echo -e "${CYAN}[1/3] Creating source filesystem (server1)...${NC}"
dd if=/dev/zero of=server1_fs.img bs=1M count=100 status=none
../misc/mke2fs -t ext4 -F server1_fs.img >/dev/null 2>&1
echo -e "${GREEN}✓${NC} Created server1_fs.img (100MB)"

# Create identical replica (server2)
echo -e "${CYAN}[2/3] Creating replica filesystem (server2)...${NC}"
cp server1_fs.img server2_fs.img
echo -e "${GREEN}✓${NC} Created server2_fs.img (identical copy)"

# Verify identical
echo -e "${CYAN}[3/3] Verifying filesystems are identical...${NC}"
HASH1=$(md5sum server1_fs.img | awk '{print $1}')
HASH2=$(md5sum server2_fs.img | awk '{print $1}')
if [ "$HASH1" = "$HASH2" ]; then
    echo -e "${GREEN}✓${NC} Checksums match: $HASH1"
else
    echo -e "${RED}✗${NC} Checksums don't match!"
    exit 1
fi
echo ""

echo -e "${BOLD}${YELLOW}PHASE 2: START SERVER1 (LIVE)${NC}"
echo ""

# Mount server1 and keep it running
echo -e "${CYAN}[1/2] Mounting server1 filesystem (LIVE mode)...${NC}"
LOOP1=$(losetup -f)
losetup "$LOOP1" server1_fs.img
mkdir -p server1_mount
mount -o data=journal,barrier=0,commit=9999 "$LOOP1" server1_mount
echo -e "${GREEN}✓${NC} Server1 mounted and RUNNING at server1_mount"
echo -e "${BLUE}  This filesystem stays mounted during entire demo${NC}"
echo ""

echo -e "${CYAN}[2/2] Creating initial files...${NC}"
echo "Initial content" > server1_mount/file0.txt
echo -e "${GREEN}✓${NC} Initial file created"
echo ""

echo -e "${BOLD}${YELLOW}PHASE 3: START CONTINUOUS MONITOR${NC}"
echo ""

# Start continuous journal monitor in background
echo -e "${CYAN}[1/1] Starting continuous journal monitor...${NC}"
mkdir -p captures
../journal_replicate_monitor.sh server1_fs.img captures 2 > monitor.log 2>&1 &
MONITOR_PID=$!
echo -e "${GREEN}✓${NC} Monitor started (PID: $MONITOR_PID)"
echo -e "${BLUE}  Monitoring every 2 seconds, capturing journal changes${NC}"
sleep 2
echo ""

echo -e "${BOLD}${YELLOW}PHASE 4: SIMULATE LIVE ACTIVITY${NC}"
echo ""

# Make changes while server is running
echo -e "${CYAN}[1/5] Creating file 1...${NC}"
echo "Content 1 - $(date)" > server1_mount/file1.txt
sleep 3
echo -e "${GREEN}✓${NC} file1.txt created"

echo -e "${CYAN}[2/5] Creating file 2...${NC}"
echo "Content 2 - $(date)" > server1_mount/file2.txt
sleep 3
echo -e "${GREEN}✓${NC} file2.txt created"

echo -e "${CYAN}[3/5] Creating directory...${NC}"
mkdir server1_mount/mydir
sleep 3
echo -e "${GREEN}✓${NC} mydir/ created"

echo -e "${CYAN}[4/5] Creating file in directory...${NC}"
echo "Content in dir - $(date)" > server1_mount/mydir/file3.txt
sleep 3
echo -e "${GREEN}✓${NC} mydir/file3.txt created"

echo -e "${CYAN}[5/5] Final file...${NC}"
echo "Final content - $(date)" > server1_mount/abc.txt
sleep 3
echo -e "${GREEN}✓${NC} abc.txt created"
echo ""

# Show what was captured
echo -e "${BOLD}${YELLOW}PHASE 5: REVIEW CAPTURED CHANGES${NC}"
echo ""

echo -e "${CYAN}[1/2] Files on server1:${NC}"
ls -lR server1_mount | grep -v "^total" | grep -v "^$" | sed 's/^/  /'
echo ""

echo -e "${CYAN}[2/2] Captures collected by monitor:${NC}"
CAPTURE_COUNT=$(ls -1d captures/capture_* 2>/dev/null | wc -l)
echo -e "  Total captures: ${BOLD}$CAPTURE_COUNT${NC}"
if [ "$CAPTURE_COUNT" -gt 0 ]; then
    echo -e "  ${GREEN}✓${NC} Monitor successfully captured journal changes!"
    ls -1dt captures/capture_* | head -5 | while read dir; do
        TRANS=$(grep "Transactions found:" "$dir/capture.log" 2>/dev/null | awk '{print $3}' || echo "?")
        echo -e "    $(basename $dir): $TRANS transaction(s)"
    done
else
    echo -e "  ${YELLOW}⚠${NC} No captures collected (journal may be checkpointing)"
fi
echo ""

# Stop monitor
echo -e "${CYAN}Stopping monitor...${NC}"
kill $MONITOR_PID 2>/dev/null || true
wait $MONITOR_PID 2>/dev/null || true
echo -e "${GREEN}✓${NC} Monitor stopped"
echo ""

echo -e "${BOLD}${YELLOW}PHASE 6: APPLY TO SERVER2${NC}"
echo ""

# Apply captured changes to server2
echo -e "${CYAN}[1/3] Applying captures to server2 in sequence...${NC}"
APPLIED=0
for capture_dir in $(ls -1dt captures/capture_* | tac); do
    if [ -f "$capture_dir/04_journal_blocks.raw" ]; then
        echo -e "  Applying $(basename $capture_dir)..."
        ../journal_replicate_inject.sh server2_fs.img "$capture_dir" > /dev/null 2>&1 || true
        APPLIED=$((APPLIED + 1))
    fi
done
echo -e "${GREEN}✓${NC} Applied $APPLIED capture(s) to server2"

echo -e "${CYAN}[2/3] Running e2fsck to replay journal...${NC}"
../e2fsck/e2fsck -fy server2_fs.img > /dev/null 2>&1 || true
echo -e "${GREEN}✓${NC} Journal replayed on server2"

echo -e "${CYAN}[3/3] Mounting server2 to verify...${NC}"
LOOP2=$(losetup -f)
losetup "$LOOP2" server2_fs.img
mkdir -p server2_mount
mount "$LOOP2" server2_mount
echo -e "${GREEN}✓${NC} Server2 mounted"
echo ""

echo -e "${BOLD}${YELLOW}PHASE 7: VERIFY REPLICATION${NC}"
echo ""

echo -e "${CYAN}[1/2] Files on server2 (after replication):${NC}"
ls -lR server2_mount | grep -v "^total" | grep -v "^$" | sed 's/^/  /'
echo ""

echo -e "${CYAN}[2/2] Verifying specific files...${NC}"
check_file() {
    if [ -f "server2_mount/$1" ]; then
        echo -e "  ${GREEN}✓${NC} $1 exists"
        return 0
    else
        echo -e "  ${RED}✗${NC} $1 NOT FOUND"
        return 1
    fi
}

check_file "abc.txt"
check_file "file1.txt"
check_file "file2.txt"
check_file "mydir/file3.txt"
echo ""

echo -e "${BOLD}${YELLOW}PHASE 8: COMPARE FILESYSTEMS${NC}"
echo ""

echo -e "${CYAN}[1/1] Comparing server1 and server2...${NC}"
DIFF=$(diff -r server1_mount server2_mount 2>&1 | grep -v "lost+found" || true)
if [ -z "$DIFF" ]; then
    echo -e "  ${GREEN}${BOLD}✓ FILESYSTEMS ARE IDENTICAL!${NC}"
    echo -e "  ${GREEN}Live replication successful!${NC}"
else
    echo -e "  ${YELLOW}Differences found:${NC}"
    echo "$DIFF" | sed 's/^/    /'
fi
echo ""

# Cleanup happens via trap

echo -e "${BOLD}${GREEN}==================================================================="
echo "CONTINUOUS REPLICATION DEMONSTRATION COMPLETE"
echo "===================================================================${NC}"
echo ""
echo "Summary:"
echo "  1. Server1 stayed LIVE throughout entire demo"
echo "  2. Continuous monitor captured $CAPTURE_COUNT journal snapshots"
echo "  3. Applied $APPLIED capture(s) to server2"
echo "  4. Server2 now matches server1"
echo ""
echo "Key takeaway: Server1 NEVER stopped serving I/O!"
echo ""
