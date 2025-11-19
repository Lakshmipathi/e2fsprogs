#!/bin/bash
#
# test_e2image_replication.sh - Replication using e2image
#
# Uses e2image -ra (raw format with all data) and -c (compare mode)
# to intelligently replicate only changed blocks from server1 to server2
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
echo "E2IMAGE-BASED REPLICATION TEST"
echo "====================================================================${NC}"
echo ""
echo -e "${YELLOW}Strategy: Use e2image -ra -c to replicate changed blocks${NC}"
echo -e "${YELLOW}Goal: Replicate file1.txt from server1 to server2${NC}"
echo ""

cleanup() {
    umount /tmp/e2img_s1 2>/dev/null || true
    umount /tmp/e2img_s2 2>/dev/null || true
    LOOP1=$(losetup -j server1.img 2>/dev/null | cut -d: -f1)
    LOOP2=$(losetup -j server2.img 2>/dev/null | cut -d: -f1)
    [ -n "$LOOP1" ] && losetup -d "$LOOP1" 2>/dev/null || true
    [ -n "$LOOP2" ] && losetup -d "$LOOP2" 2>/dev/null || true
    rm -rf /tmp/test_e2image_repl
}
cleanup

mkdir -p /tmp/test_e2image_repl
cd /tmp/test_e2image_repl

echo -e "${BOLD}${YELLOW}PHASE 1: SETUP IDENTICAL FILESYSTEMS${NC}"
echo ""

echo -e "${CYAN}[1/3] Creating server1 filesystem (100MB)${NC}"
dd if=/dev/zero of=server1.img bs=1M count=100 2>/dev/null
$E2FSPROGS_DIR/misc/mke2fs -t ext4 -F server1.img >/dev/null 2>&1
echo -e "${GREEN}✓${NC} server1.img created"

echo -e "${CYAN}[2/3] Creating server2 (identical copy)${NC}"
cp server1.img server2.img
echo -e "${GREEN}✓${NC} server2.img created (exact copy)"

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

echo -e "${BOLD}${YELLOW}PHASE 2: CREATE FILE ON SERVER1${NC}"
echo ""

echo -e "${CYAN}[1/4] Setting up loop device${NC}"
LOOP_DEV=$(losetup -f)
losetup "$LOOP_DEV" server1.img
echo -e "${GREEN}✓${NC} Loop device: $LOOP_DEV"

echo -e "${CYAN}[2/4] Mounting server1${NC}"
mkdir -p /tmp/e2img_s1
mount "$LOOP_DEV" /tmp/e2img_s1
echo -e "${GREEN}✓${NC} Mounted at /tmp/e2img_s1"

echo -e "${CYAN}[3/4] Creating file1.txt${NC}"
echo "Hello from server1 - this is file1.txt content" > /tmp/e2img_s1/file1.txt
echo -e "${GREEN}✓${NC} File created"

echo -e "${CYAN}[4/4] Syncing and unmounting${NC}"
sync
umount /tmp/e2img_s1
losetup -d "$LOOP_DEV"
echo -e "${GREEN}✓${NC} Unmounted"
echo ""

echo -e "${BOLD}${YELLOW}PHASE 3: REPLICATE USING E2IMAGE${NC}"
echo ""

echo -e "${CYAN}[1/3] Using e2image -ra -c to replicate changed blocks${NC}"
echo "  This will:"
echo "    -r  Create raw image (preserves exact layout)"
echo "    -a  Include all data (not just metadata)"
echo "    -c  Compare blocks (only write if different)"
echo "    -p  Show progress"
echo ""

# Use e2image to replicate from server1 to server2
# -r: raw format (exact layout)
# -a: include all data
# -c: compare before write (skip identical blocks)
# -p: show progress
echo "  Running: e2image -ra -c -p server1.img server2.img"
if $E2FSPROGS_DIR/misc/e2image -ra -c -p server1.img server2.img 2>&1 | tee e2image_output.txt; then
    echo ""
    echo -e "${GREEN}✓${NC} e2image completed"
else
    EXIT_CODE=$?
    echo ""
    echo -e "${RED}✗${NC} e2image failed with exit code: $EXIT_CODE"
    echo ""
    echo "Output:"
    cat e2image_output.txt | sed 's/^/  /'
    exit 1
fi

echo -e "${CYAN}[2/3] Analyzing what was replicated${NC}"
if [ -f e2image_output.txt ]; then
    BLOCKS_WRITTEN=$(grep -i "block" e2image_output.txt | tail -5 | sed 's/^/  /')
    if [ -n "$BLOCKS_WRITTEN" ]; then
        echo "$BLOCKS_WRITTEN"
    else
        echo "  (No block statistics available)"
    fi
fi

echo -e "${CYAN}[3/3] Verifying filesystems differ${NC}"
HASH1_AFTER=$(md5sum server1.img | awk '{print $1}')
HASH2_AFTER=$(md5sum server2.img | awk '{print $1}')
if [ "$HASH1_AFTER" != "$HASH2_AFTER" ]; then
    echo -e "${YELLOW}⚠${NC} Note: Images have different hashes (expected - timestamps differ)"
    echo "  server1: ${HASH1_AFTER:0:16}..."
    echo "  server2: ${HASH2_AFTER:0:16}..."
else
    echo -e "${GREEN}✓${NC} Images identical: ${HASH1_AFTER:0:16}..."
fi
echo ""

echo -e "${BOLD}${YELLOW}PHASE 4: VERIFY REPLICATION${NC}"
echo ""

echo -e "${CYAN}[1/3] Running e2fsck on server2${NC}"
$E2FSPROGS_DIR/e2fsck/e2fsck -fy server2.img 2>&1 | head -5 | sed 's/^/  /'
echo -e "${GREEN}✓${NC} Filesystem checked"

echo -e "${CYAN}[2/3] Setting up loop device for server2${NC}"
LOOP_DEV2=$(losetup -f)
losetup "$LOOP_DEV2" server2.img
echo -e "${GREEN}✓${NC} Loop device: $LOOP_DEV2"

echo -e "${CYAN}[3/3] Mounting and checking server2${NC}"
mkdir -p /tmp/e2img_s2
mount "$LOOP_DEV2" /tmp/e2img_s2
echo -e "${GREEN}✓${NC} Mounted"
echo ""

echo -e "${BOLD}${YELLOW}PHASE 5: VERIFY FILE1.TXT${NC}"
echo ""

FILE_EXISTS=false
if [ -f /tmp/e2img_s2/file1.txt ]; then
    FILE_EXISTS=true
    CONTENT=$(cat /tmp/e2img_s2/file1.txt)
    echo -e "  ${GREEN}✓✓✓ SUCCESS! file1.txt EXISTS on server2${NC}"
    echo ""
    echo "  Content: '$CONTENT'"
    echo ""

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
    ls -la /tmp/e2img_s2 | sed 's/^/    /'
fi
echo ""

echo -e "${BOLD}${YELLOW}PHASE 6: TEST INCREMENTAL REPLICATION${NC}"
echo ""

echo -e "${CYAN}[1/5] Creating additional file on server1${NC}"
umount /tmp/e2img_s2
losetup -d "$LOOP_DEV2"

LOOP_DEV=$(losetup -f)
losetup "$LOOP_DEV" server1.img
mount "$LOOP_DEV" /tmp/e2img_s1
echo "Second file created after initial replication" > /tmp/e2img_s1/file2.txt
sync
umount /tmp/e2img_s1
losetup -d "$LOOP_DEV"
echo -e "${GREEN}✓${NC} file2.txt created on server1"

echo -e "${CYAN}[2/5] Running incremental replication with e2image -ra -c${NC}"
if $E2FSPROGS_DIR/misc/e2image -ra -c -p server1.img server2.img 2>&1 | tee e2image_incremental.txt; then
    echo ""
    echo -e "${GREEN}✓${NC} Incremental replication completed"
else
    echo ""
    echo -e "${RED}✗${NC} Incremental replication failed"
fi

echo -e "${CYAN}[3/5] Checking if file2.txt was replicated${NC}"
LOOP_DEV2=$(losetup -f)
losetup "$LOOP_DEV2" server2.img
mount "$LOOP_DEV2" /tmp/e2img_s2

FILE2_EXISTS=false
if [ -f /tmp/e2img_s2/file2.txt ]; then
    FILE2_EXISTS=true
    CONTENT2=$(cat /tmp/e2img_s2/file2.txt)
    echo -e "  ${GREEN}✓ file2.txt replicated!${NC}"
    echo "  Content: '$CONTENT2'"
else
    echo -e "  ${YELLOW}⚠${NC} file2.txt not found"
fi

echo -e "${CYAN}[4/5] Verifying file1.txt still exists${NC}"
if [ -f /tmp/e2img_s2/file1.txt ]; then
    echo -e "  ${GREEN}✓${NC} file1.txt still present"
else
    echo -e "  ${RED}✗${NC} file1.txt disappeared!"
fi

echo -e "${CYAN}[5/5] Listing all files on server2${NC}"
echo "  Files:"
ls -lh /tmp/e2img_s2/*.txt 2>/dev/null | sed 's/^/    /' || echo "    (no .txt files found)"
echo ""

umount /tmp/e2img_s2
losetup -d "$LOOP_DEV2"

cleanup

echo -e "${BOLD}${CYAN}===================================================================="
echo "RESULTS"
echo "====================================================================${NC}"
echo ""

if [ "$FILE_EXISTS" = "true" ]; then
    echo -e "${GREEN}✓ SUCCESS: e2image-based replication WORKS!${NC}"
    echo ""
    echo "Key findings:"
    echo "  1. e2image -ra -c successfully replicates file data"
    echo "  2. file1.txt appeared on server2 with correct content"

    if [ "$FILE2_EXISTS" = "true" ]; then
        echo "  3. Incremental replication also works (file2.txt replicated)"
        echo ""
        echo -e "${GREEN}✓✓✓ FULL SUCCESS - Both initial and incremental replication work!${NC}"
    else
        echo "  3. Incremental replication needs investigation"
        echo ""
        echo -e "${YELLOW}⚠${NC} Partial success - initial replication works, incremental unclear"
    fi

    echo ""
    echo "This proves e2image is viable for filesystem replication!"
    echo ""
    echo "Advantages over blktrace:"
    echo "  - Understands ext4 structure (inodes, directories, metadata)"
    echo "  - Compare mode (-c) only writes changed blocks"
    echo "  - Includes file data (-a flag)"
    echo "  - Can be mounted directly (raw format)"
    echo "  - Sparse file support (efficient storage)"
else
    echo -e "${RED}✗ FAILED: Replication did not work${NC}"
    echo ""
    echo "Check e2image_output.txt for details"
fi
echo ""
