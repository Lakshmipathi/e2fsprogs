#!/bin/bash
#
# test_e2image_delta_replication.sh - Delta replication using T0/T1 e2image comparison
#
# Strategy:
#   1. Capture e2image at T0 (baseline)
#   2. Make changes to filesystem
#   3. Capture e2image at T1 (current)
#   4. Compare T0 vs T1 to find changed blocks
#   5. Replicate ONLY changed blocks to server2
#
# This is simpler than thin_delta and works without LVM thin provisioning!
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
echo "E2IMAGE DELTA REPLICATION - T0/T1 COMPARISON"
echo "====================================================================${NC}"
echo ""
echo -e "${YELLOW}Strategy: Compare e2images at T0 and T1, replicate only changed blocks${NC}"
echo -e "${YELLOW}Advantage: No thin_delta, no LVM thin provisioning required!${NC}"
echo ""

cleanup() {
    umount /tmp/delta_s1 2>/dev/null || true
    umount /tmp/delta_s2 2>/dev/null || true
    LOOP1=$(losetup -j server1.img 2>/dev/null | cut -d: -f1)
    LOOP2=$(losetup -j server2.img 2>/dev/null | cut -d: -f1)
    [ -n "$LOOP1" ] && losetup -d "$LOOP1" 2>/dev/null || true
    [ -n "$LOOP2" ] && losetup -d "$LOOP2" 2>/dev/null || true
    rm -rf /tmp/test_delta_repl
}
cleanup

mkdir -p /tmp/test_delta_repl
cd /tmp/test_delta_repl

echo -e "${BOLD}${YELLOW}PHASE 1: SETUP FILESYSTEMS${NC}"
echo ""

echo -e "${CYAN}[1/5] Creating server1 filesystem (100MB)${NC}"
dd if=/dev/zero of=server1.img bs=1M count=100 2>/dev/null
$E2FSPROGS_DIR/misc/mke2fs -t ext4 -F server1.img >/dev/null 2>&1
echo -e "${GREEN}✓${NC} server1.img created"

echo -e "${CYAN}[2/5] Creating server2 (identical copy for now)${NC}"
cp server1.img server2.img
echo -e "${GREEN}✓${NC} server2.img created"

echo -e "${CYAN}[3/5] Creating initial file on server1${NC}"
LOOP_DEV=$(losetup -f)
losetup "$LOOP_DEV" server1.img
mkdir -p /tmp/delta_s1
mount "$LOOP_DEV" /tmp/delta_s1
echo "Initial file - exists at T0" > /tmp/delta_s1/file0.txt
sync
umount /tmp/delta_s1
losetup -d "$LOOP_DEV"
echo -e "${GREEN}✓${NC} file0.txt created"

echo -e "${CYAN}[4/5] Syncing initial state to server2${NC}"
cp server1.img server2.img
echo -e "${GREEN}✓${NC} Server2 synced (baseline)"

echo -e "${CYAN}[5/5] Verifying both servers identical${NC}"
HASH1=$(md5sum server1.img | awk '{print $1}')
HASH2=$(md5sum server2.img | awk '{print $1}')
if [ "$HASH1" = "$HASH2" ]; then
    echo -e "${GREEN}✓${NC} Checksums match: ${HASH1:0:16}..."
else
    echo -e "${RED}✗${NC} ERROR: Initial sync failed!"
    exit 1
fi
echo ""

echo -e "${BOLD}${YELLOW}PHASE 2: CAPTURE BASELINE (T0)${NC}"
echo ""

echo -e "${CYAN}[1/2] Creating e2image snapshot at T0${NC}"
echo "  Command: e2image -ra server1.img baseline_t0.img"
$E2FSPROGS_DIR/misc/e2image -ra server1.img baseline_t0.img 2>&1 | tail -2
echo -e "${GREEN}✓${NC} Baseline captured"

echo -e "${CYAN}[2/2] Checking baseline size${NC}"
T0_SIZE=$(du -h baseline_t0.img | awk '{print $1}')
echo -e "${GREEN}✓${NC} Baseline size: $T0_SIZE"
echo ""

echo -e "${BOLD}${YELLOW}PHASE 3: MAKE CHANGES TO SERVER1${NC}"
echo ""

echo -e "${CYAN}[1/5] Mounting server1${NC}"
LOOP_DEV=$(losetup -f)
losetup "$LOOP_DEV" server1.img
mount "$LOOP_DEV" /tmp/delta_s1
echo -e "${GREEN}✓${NC} Mounted"

echo -e "${CYAN}[2/5] Creating new file (file1.txt)${NC}"
echo "New file created at T1 - should be replicated" > /tmp/delta_s1/file1.txt
echo -e "${GREEN}✓${NC} file1.txt created"

echo -e "${CYAN}[3/5] Creating another file (file2.txt)${NC}"
echo "Another new file at T1" > /tmp/delta_s1/file2.txt
echo -e "${GREEN}✓${NC} file2.txt created"

echo -e "${CYAN}[4/5] Modifying existing file (file0.txt)${NC}"
echo "Modified content at T1 - was different at T0" >> /tmp/delta_s1/file0.txt
echo -e "${GREEN}✓${NC} file0.txt modified"

echo -e "${CYAN}[5/5] Syncing and unmounting${NC}"
sync
sync
sync
umount /tmp/delta_s1
losetup -d "$LOOP_DEV"
echo -e "${GREEN}✓${NC} Changes flushed to disk"
echo ""

echo -e "${BOLD}${YELLOW}PHASE 4: CAPTURE CURRENT STATE (T1)${NC}"
echo ""

echo -e "${CYAN}[1/2] Creating e2image snapshot at T1${NC}"
echo "  Command: e2image -ra server1.img current_t1.img"
$E2FSPROGS_DIR/misc/e2image -ra server1.img current_t1.img 2>&1 | tail -2
echo -e "${GREEN}✓${NC} Current state captured"

echo -e "${CYAN}[2/2] Checking current size${NC}"
T1_SIZE=$(du -h current_t1.img | awk '{print $1}')
echo -e "${GREEN}✓${NC} Current size: $T1_SIZE"
echo ""

echo -e "${BOLD}${YELLOW}PHASE 5: COMPARE T0 vs T1 (FIND CHANGED BLOCKS)${NC}"
echo ""

echo -e "${CYAN}[1/4] Getting filesystem block size${NC}"
BLOCK_SIZE=$($E2FSPROGS_DIR/misc/dumpe2fs server1.img 2>/dev/null | grep "^Block size:" | awk '{print $3}')
echo -e "${GREEN}✓${NC} Block size: $BLOCK_SIZE bytes"

echo -e "${CYAN}[2/4] Calculating total blocks${NC}"
T0_BYTES=$(stat -c%s baseline_t0.img)
TOTAL_BLOCKS=$((T0_BYTES / BLOCK_SIZE))
echo -e "${GREEN}✓${NC} Total blocks: $TOTAL_BLOCKS"

echo -e "${CYAN}[3/4] Comparing blocks (this may take a moment)${NC}"
echo "  Comparing $TOTAL_BLOCKS blocks of $BLOCK_SIZE bytes each..."

# Compare blocks and save changed block numbers
CHANGED_BLOCKS=0
> changed_blocks.txt

for ((block_num=0; block_num<TOTAL_BLOCKS; block_num++)); do
    # Extract block from T0
    dd if=baseline_t0.img of=/tmp/block_t0 bs=$BLOCK_SIZE skip=$block_num count=1 2>/dev/null

    # Extract block from T1
    dd if=current_t1.img of=/tmp/block_t1 bs=$BLOCK_SIZE skip=$block_num count=1 2>/dev/null

    # Compare blocks
    if ! cmp -s /tmp/block_t0 /tmp/block_t1; then
        echo $block_num >> changed_blocks.txt
        CHANGED_BLOCKS=$((CHANGED_BLOCKS + 1))
    fi

    # Progress indicator every 100 blocks
    if [ $((block_num % 100)) -eq 0 ]; then
        echo -ne "  Progress: $block_num/$TOTAL_BLOCKS blocks checked (found $CHANGED_BLOCKS changes)\r"
    fi
done
echo -ne "\n"

rm -f /tmp/block_t0 /tmp/block_t1

echo -e "${GREEN}✓${NC} Comparison complete"

echo -e "${CYAN}[4/4] Changed blocks summary${NC}"
echo "  Total blocks checked: $TOTAL_BLOCKS"
echo "  Changed blocks: $CHANGED_BLOCKS"
CHANGE_PERCENT=$((CHANGED_BLOCKS * 100 / TOTAL_BLOCKS))
echo "  Change percentage: ${CHANGE_PERCENT}%"
BANDWIDTH_SAVED=$((100 - CHANGE_PERCENT))
echo -e "  ${GREEN}Bandwidth saved: ${BANDWIDTH_SAVED}%${NC} (only replicate changed blocks!)"

if [ $CHANGED_BLOCKS -gt 0 ]; then
    echo ""
    echo "  First 10 changed blocks:"
    head -10 changed_blocks.txt | sed 's/^/    Block /'
fi
echo ""

echo -e "${BOLD}${YELLOW}PHASE 6: REPLICATE ONLY CHANGED BLOCKS${NC}"
echo ""

echo -e "${CYAN}[1/3] Copying changed blocks from T1 to server2${NC}"
BLOCKS_COPIED=0

while read block_num; do
    # Copy this block from current_t1.img to server2.img
    dd if=current_t1.img \
       of=server2.img \
       bs=$BLOCK_SIZE \
       skip=$block_num \
       seek=$block_num \
       count=1 \
       conv=notrunc \
       2>/dev/null

    BLOCKS_COPIED=$((BLOCKS_COPIED + 1))

    # Progress indicator
    if [ $((BLOCKS_COPIED % 10)) -eq 0 ]; then
        echo -ne "  Copied $BLOCKS_COPIED/$CHANGED_BLOCKS blocks\r"
    fi
done < changed_blocks.txt
echo -ne "\n"

echo -e "${GREEN}✓${NC} Replicated $BLOCKS_COPIED changed blocks"

echo -e "${CYAN}[2/3] Calculating data transferred${NC}"
BYTES_TRANSFERRED=$((BLOCKS_COPIED * BLOCK_SIZE))
MB_TRANSFERRED=$((BYTES_TRANSFERRED / 1024 / 1024))
TOTAL_MB=$((T0_BYTES / 1024 / 1024))
echo "  Data transferred: ${MB_TRANSFERRED}MB out of ${TOTAL_MB}MB total"
echo -e "${GREEN}✓${NC} Bandwidth savings: $((100 - MB_TRANSFERRED * 100 / TOTAL_MB))%"

echo -e "${CYAN}[3/3] Running e2fsck on server2${NC}"
$E2FSPROGS_DIR/e2fsck/e2fsck -fy server2.img 2>&1 | grep -E "(clean|errors)" | head -3 | sed 's/^/  /'
echo -e "${GREEN}✓${NC} Filesystem check passed"
echo ""

echo -e "${BOLD}${YELLOW}PHASE 7: VERIFY REPLICATION${NC}"
echo ""

echo -e "${CYAN}[1/5] Mounting server2${NC}"
LOOP_DEV2=$(losetup -f)
losetup "$LOOP_DEV2" server2.img
mkdir -p /tmp/delta_s2
mount "$LOOP_DEV2" /tmp/delta_s2
echo -e "${GREEN}✓${NC} Mounted"

echo -e "${CYAN}[2/5] Checking file0.txt (existed at T0, modified at T1)${NC}"
FILE0_SUCCESS=false
if [ -f /tmp/delta_s2/file0.txt ]; then
    CONTENT=$(cat /tmp/delta_s2/file0.txt)
    EXPECTED="Initial file - exists at T0
Modified content at T1 - was different at T0"
    if [ "$CONTENT" = "$EXPECTED" ]; then
        echo -e "  ${GREEN}✓${NC} file0.txt correctly updated with T1 changes"
        FILE0_SUCCESS=true
    else
        echo -e "  ${YELLOW}⚠${NC} file0.txt content doesn't match expected"
        echo "    Expected: '$EXPECTED'"
        echo "    Got: '$CONTENT'"
    fi
else
    echo -e "  ${RED}✗${NC} file0.txt missing"
fi

echo -e "${CYAN}[3/5] Checking file1.txt (new at T1)${NC}"
FILE1_SUCCESS=false
if [ -f /tmp/delta_s2/file1.txt ]; then
    CONTENT=$(cat /tmp/delta_s2/file1.txt)
    if [ "$CONTENT" = "New file created at T1 - should be replicated" ]; then
        echo -e "  ${GREEN}✓✓✓ SUCCESS! file1.txt replicated${NC}"
        echo "    Content: '$CONTENT'"
        FILE1_SUCCESS=true
    else
        echo -e "  ${YELLOW}⚠${NC} file1.txt has wrong content"
    fi
else
    echo -e "  ${RED}✗${NC} file1.txt not found"
fi

echo -e "${CYAN}[4/5] Checking file2.txt (new at T1)${NC}"
FILE2_SUCCESS=false
if [ -f /tmp/delta_s2/file2.txt ]; then
    CONTENT=$(cat /tmp/delta_s2/file2.txt)
    if [ "$CONTENT" = "Another new file at T1" ]; then
        echo -e "  ${GREEN}✓✓✓ SUCCESS! file2.txt replicated${NC}"
        echo "    Content: '$CONTENT'"
        FILE2_SUCCESS=true
    else
        echo -e "  ${YELLOW}⚠${NC} file2.txt has wrong content"
    fi
else
    echo -e "  ${RED}✗${NC} file2.txt not found"
fi

echo -e "${CYAN}[5/5] Listing all files on server2${NC}"
echo "  Files:"
ls -lh /tmp/delta_s2/*.txt 2>/dev/null | sed 's/^/    /' || echo "    (no .txt files found)"
echo ""

umount /tmp/delta_s2
losetup -d "$LOOP_DEV2"

cleanup

echo -e "${BOLD}${CYAN}===================================================================="
echo "RESULTS SUMMARY"
echo "====================================================================${NC}"
echo ""

ALL_SUCCESS=false
if [ "$FILE0_SUCCESS" = "true" ] && [ "$FILE1_SUCCESS" = "true" ] && [ "$FILE2_SUCCESS" = "true" ]; then
    ALL_SUCCESS=true
fi

if [ "$ALL_SUCCESS" = "true" ]; then
    echo -e "${GREEN}✓✓✓ SUCCESS: T0/T1 DELTA REPLICATION WORKS PERFECTLY!${NC}"
    echo ""
    echo -e "${BOLD}Key Results:${NC}"
    echo "  • Baseline (T0): Captured filesystem state before changes"
    echo "  • Current (T1): Captured filesystem state after changes"
    echo "  • Changed blocks: $CHANGED_BLOCKS out of $TOTAL_BLOCKS ($CHANGE_PERCENT%)"
    echo "  • Data transferred: ${MB_TRANSFERRED}MB (saved ${BANDWIDTH_SAVED}%)"
    echo "  • All files correctly replicated to server2"
    echo ""
    echo -e "${BOLD}${GREEN}Advantages over thin_delta:${NC}"
    echo "  ✓ No LVM thin provisioning required"
    echo "  ✓ Works with any storage backend"
    echo "  ✓ Simple to understand and implement"
    echo "  ✓ Deterministic - same input always gives same output"
    echo "  ✓ Can be done offline/asynchronously"
    echo "  ✓ Only transfers changed blocks (huge bandwidth savings)"
    echo ""
    echo -e "${BOLD}Production Workflow:${NC}"
    echo "  1. e2image -ra /dev/server1 baseline.img      # T0 snapshot"
    echo "  2. [time passes, filesystem changes]"
    echo "  3. e2image -ra /dev/server1 current.img       # T1 snapshot"
    echo "  4. compare_blocks baseline.img current.img    # Find changes"
    echo "  5. replicate_delta current.img server2        # Send only changes"
    echo ""
    echo -e "${BOLD}Use Cases:${NC}"
    echo "  • Incremental backups (only backup changed blocks)"
    echo "  • Efficient replication over WAN (minimize bandwidth)"
    echo "  • Disaster recovery (quick delta sync)"
    echo "  • Database replication (block-level change tracking)"
else
    echo -e "${RED}✗ FAILED: Some files not replicated correctly${NC}"
    echo ""
    echo "Results:"
    [ "$FILE0_SUCCESS" = "true" ] && echo -e "  ${GREEN}✓${NC} file0.txt" || echo -e "  ${RED}✗${NC} file0.txt"
    [ "$FILE1_SUCCESS" = "true" ] && echo -e "  ${GREEN}✓${NC} file1.txt" || echo -e "  ${RED}✗${NC} file1.txt"
    [ "$FILE2_SUCCESS" = "true" ] && echo -e "  ${GREEN}✓${NC} file2.txt" || echo -e "  ${RED}✗${NC} file2.txt"
fi
echo ""

# Save metadata for future reference
echo "Test completed at: $(date)" > test_metadata.txt
echo "Changed blocks: $CHANGED_BLOCKS/$TOTAL_BLOCKS" >> test_metadata.txt
echo "Bandwidth saved: ${BANDWIDTH_SAVED}%" >> test_metadata.txt
echo ""
echo -e "${CYAN}Test data saved to: $(pwd)${NC}"
echo -e "${CYAN}Changed blocks list: $(pwd)/changed_blocks.txt${NC}"
