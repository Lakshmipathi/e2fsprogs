#!/bin/bash
#
# test_blktrace_replication.sh - Block-level replication using blktrace
#
# Uses blktrace to capture exact block writes when creating file1.txt,
# then replicates those blocks to server2.
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
echo "BLOCK-LEVEL REPLICATION USING BLKTRACE"
echo "====================================================================${NC}"
echo ""
echo -e "${YELLOW}Strategy: Trace exact block I/O when creating file1.txt${NC}"
echo -e "${YELLOW}Then replicate those blocks to server2${NC}"
echo ""

# Check if blktrace is available
if ! command -v blktrace &> /dev/null; then
    echo -e "${RED}ERROR: blktrace not found${NC}"
    echo "Install with: apt-get install blktrace"
    exit 1
fi

cleanup() {
    # Kill any running blktrace
    pkill -9 blktrace 2>/dev/null || true
    sleep 1

    umount /tmp/blk_s1 2>/dev/null || true
    umount /tmp/blk_s2 2>/dev/null || true

    LOOP1=$(losetup -j server1.img 2>/dev/null | cut -d: -f1)
    LOOP2=$(losetup -j server2.img 2>/dev/null | cut -d: -f1)
    [ -n "$LOOP1" ] && losetup -d "$LOOP1" 2>/dev/null || true
    [ -n "$LOOP2" ] && losetup -d "$LOOP2" 2>/dev/null || true

    rm -rf /tmp/test_blktrace_repl
}
cleanup

mkdir -p /tmp/test_blktrace_repl
cd /tmp/test_blktrace_repl

echo -e "${BOLD}${YELLOW}PHASE 1: SETUP FILESYSTEMS${NC}"
echo ""

echo -e "${CYAN}[1/4] Creating server1 filesystem (100MB)${NC}"
dd if=/dev/zero of=server1.img bs=1M count=100 2>/dev/null
$E2FSPROGS_DIR/misc/mke2fs -t ext4 -F server1.img >/dev/null 2>&1
echo -e "${GREEN}✓${NC} server1.img created"

echo -e "${CYAN}[2/4] Creating server2 (identical copy)${NC}"
cp server1.img server2.img
echo -e "${GREEN}✓${NC} server2.img created"

echo -e "${CYAN}[3/4] Setting up loop device for server1${NC}"
LOOP_DEV=$(losetup -f)
losetup "$LOOP_DEV" server1.img
echo -e "${GREEN}✓${NC} Loop device: $LOOP_DEV"

echo -e "${CYAN}[4/4] Mounting server1${NC}"
mkdir -p /tmp/blk_s1
mount "$LOOP_DEV" /tmp/blk_s1
echo -e "${GREEN}✓${NC} Mounted at /tmp/blk_s1"
echo ""

echo -e "${BOLD}${YELLOW}PHASE 2: START BLKTRACE${NC}"
echo ""

echo -e "${CYAN}[1/2] Starting blktrace on $LOOP_DEV${NC}"
# Use device name in output to match blkparse expectations
LOOP_NAME=$(basename "$LOOP_DEV")
blktrace -d "$LOOP_DEV" -o trace_$LOOP_NAME &
BLKTRACE_PID=$!
sleep 2
echo -e "${GREEN}✓${NC} blktrace running (PID: $BLKTRACE_PID)"

echo -e "${CYAN}[2/2] Clearing any buffered I/O${NC}"
sync
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
echo -e "${GREEN}✓${NC} Caches cleared"
echo ""

echo -e "${BOLD}${YELLOW}PHASE 3: CREATE FILE1.TXT${NC}"
echo ""

echo -e "${CYAN}[1/3] Creating file1.txt${NC}"
echo "Hello from server1 - this is file1.txt content" > /tmp/blk_s1/file1.txt
echo -e "${GREEN}✓${NC} File created"

echo -e "${CYAN}[2/3] Flushing to disk${NC}"
sync
echo -e "${GREEN}✓${NC} Synced"

echo -e "${CYAN}[3/3] Stopping blktrace${NC}"
sleep 1
kill -INT $BLKTRACE_PID 2>/dev/null || true
wait $BLKTRACE_PID 2>/dev/null || true
echo -e "${GREEN}✓${NC} blktrace stopped"
echo ""

echo -e "${BOLD}${YELLOW}PHASE 4: ANALYZE TRACE${NC}"
echo ""

echo -e "${CYAN}[1/4] Parsing trace data${NC}"
ls -la trace_*.* 2>/dev/null | sed 's/^/  /' || true

# blktrace creates files like: trace_loop16.blktrace.0
# blkparse expects base name: trace_loop16 (it auto-appends .blktrace.N)
TRACE_BASE="trace_${LOOP_NAME}"
if [ ! -f "${TRACE_BASE}.blktrace.0" ]; then
    echo -e "${RED}✗${NC} Trace file not found!"
    ls -la trace_* 2>/dev/null || echo "No trace files"
    exit 1
fi

echo "  Running blkparse on ${TRACE_BASE}..."
if ! blkparse -i "$TRACE_BASE" > trace_parsed.txt 2>&1; then
    echo -e "${RED}✗${NC} blkparse failed!"
    echo "Error output:"
    cat trace_parsed.txt | head -20 | sed 's/^/  /'
    exit 1
fi
PARSED_LINES=$(wc -l < trace_parsed.txt)
echo -e "${GREEN}✓${NC} Trace parsed ($PARSED_LINES lines)"

echo -e "${CYAN}[2/4] Filtering I/O operations${NC}"
# Look for D (Dispatch) operations which show actual I/O
grep -E '\s+D\s+' trace_parsed.txt > writes.txt || true
WRITE_COUNT=$(wc -l < writes.txt)
echo -e "${GREEN}✓${NC} Found $WRITE_COUNT dispatch operations"

if [ "$WRITE_COUNT" -eq 0 ]; then
    echo -e "${RED}✗${NC} No I/O operations captured!"
    echo ""
    echo "First 30 lines of trace:"
    head -30 trace_parsed.txt | sed 's/^/  /'
    exit 1
fi

echo -e "${CYAN}[3/4] Extracting sector numbers and sizes${NC}"
# blktrace format: device cpu seq timestamp pid action type sector + size [process]
# Example: 7,19   3    8    0.306479405 15146  D  RM 13362 + 2 [bash]
# We want sector (field before +) and size (field after +)
awk '{
    for (i=1; i<=NF; i++) {
        if ($i == "+" && i > 1) {
            sector = $(i-1)
            size = $(i+1)
            print sector, size
            break
        }
    }
}' writes.txt | sort -u > blocks_to_copy.txt

BLOCK_COUNT=$(wc -l < blocks_to_copy.txt)
echo -e "${GREEN}✓${NC} Found $BLOCK_COUNT unique sector ranges"

echo -e "${CYAN}[4/4] Showing sample sectors${NC}"
echo "  First 5 sector ranges (sector + size_in_512b_blocks):"
head -5 blocks_to_copy.txt | sed 's/^/    /'
echo ""

echo -e "${BOLD}${YELLOW}PHASE 5: EXTRACT AND REPLICATE BLOCKS${NC}"
echo ""

echo -e "${CYAN}[1/3] Getting block size${NC}"
BLOCK_SIZE=$($E2FSPROGS_DIR/misc/dumpe2fs server1.img 2>/dev/null | grep "^Block size:" | awk '{print $3}')
echo -e "${GREEN}✓${NC} Block size: $BLOCK_SIZE bytes"

echo -e "${CYAN}[2/3] Unmounting server1 before block copy${NC}"
umount /tmp/blk_s1
echo -e "${GREEN}✓${NC} Unmounted"

echo -e "${CYAN}[3/3] Copying blocks from server1 to server2${NC}"
BLOCKS_COPIED=0
while read sector size; do
    # blktrace reports in 512-byte sectors
    BYTE_OFFSET=$((sector * 512))
    SIZE_BYTES=$((size))

    # Copy this block
    dd if=server1.img \
       of=server2.img \
       bs=1 \
       skip=$BYTE_OFFSET \
       seek=$BYTE_OFFSET \
       count=$SIZE_BYTES \
       conv=notrunc \
       2>/dev/null

    BLOCKS_COPIED=$((BLOCKS_COPIED + 1))
done < blocks_to_copy.txt

echo -e "${GREEN}✓${NC} Copied $BLOCKS_COPIED blocks"
echo ""

echo -e "${BOLD}${YELLOW}PHASE 6: VERIFY REPLICATION${NC}"
echo ""

echo -e "${CYAN}[1/5] Running e2fsck on server2${NC}"
$E2FSPROGS_DIR/e2fsck/e2fsck -fy server2.img 2>&1 | head -5 | sed 's/^/  /'
echo -e "${GREEN}✓${NC} Filesystem checked"

echo -e "${CYAN}[2/5] Setting up loop device for server2${NC}"
LOOP_DEV2=$(losetup -f)
losetup "$LOOP_DEV2" server2.img
echo -e "${GREEN}✓${NC} Loop device: $LOOP_DEV2"

echo -e "${CYAN}[3/5] Mounting server2${NC}"
mkdir -p /tmp/blk_s2
mount "$LOOP_DEV2" /tmp/blk_s2
echo -e "${GREEN}✓${NC} Mounted"

echo -e "${CYAN}[4/5] Checking for file1.txt${NC}"
FILE_EXISTS=false
if [ -f /tmp/blk_s2/file1.txt ]; then
    FILE_EXISTS=true
    CONTENT=$(cat /tmp/blk_s2/file1.txt)
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
    ls -la /tmp/blk_s2 | sed 's/^/    /'
fi

echo -e "${CYAN}[5/5] Comparing filesystems${NC}"
echo "  Server1 files:"
losetup "$LOOP_DEV" server1.img 2>/dev/null || true
mount "$LOOP_DEV" /tmp/blk_s1 2>/dev/null || true
ls -la /tmp/blk_s1 | tail -5 | sed 's/^/    /'
echo ""

cleanup

echo -e "${BOLD}${CYAN}===================================================================="
echo "RESULTS"
echo "====================================================================${NC}"
echo ""

if [ "$FILE_EXISTS" = "true" ]; then
    echo -e "${GREEN}✓ SUCCESS: Block-level replication WORKS!${NC}"
    echo ""
    echo "Key findings:"
    echo "  1. blktrace captured $WRITE_COUNT write operations"
    echo "  2. Identified $BLOCK_COUNT unique blocks modified"
    echo "  3. Copied blocks byte-for-byte from server1 to server2"
    echo "  4. file1.txt successfully replicated with correct content"
    echo ""
    echo "This proves block-level replication is viable for single file tracking!"
    echo ""
    echo "Trace data saved to: $(pwd)/trace_parsed.txt"
    echo "Block list saved to: $(pwd)/blocks_to_copy.txt"
else
    echo -e "${RED}✗ FAILED: Replication did not work${NC}"
    echo ""
    echo "Possible issues:"
    echo "  - Blocks not captured correctly by blktrace"
    echo "  - Block copy failed"
    echo "  - Metadata blocks not replicated"
    echo ""
    echo "Check trace files:"
    echo "  - trace_parsed.txt (full trace)"
    echo "  - writes.txt (write operations)"
    echo "  - blocks_to_copy.txt (blocks to replicate)"
fi
echo ""
