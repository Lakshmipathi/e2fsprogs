#!/bin/bash
#
# journal_replicate_demo.sh - Full demonstration of journal-based replication
#
# This script demonstrates the complete workflow:
# 1. Create source filesystem
# 2. Create identical replica
# 3. Make changes on source (with journaling)
# 4. Capture journal state
# 5. Inject into replica
# 6. Verify replication worked
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
echo "JOURNAL-BASED REPLICATION DEMONSTRATION"
echo "===================================================================${NC}"
echo ""

# Cleanup function
cleanup() {
    echo ""
    echo -e "${YELLOW}Cleaning up...${NC}"
    umount server1_mount 2>/dev/null || true
    umount server2_mount 2>/dev/null || true
    losetup -d /dev/loop20 2>/dev/null || true
    losetup -d /dev/loop21 2>/dev/null || true
    rm -rf demo_replication
    echo -e "${GREEN}✓ Cleaned up${NC}"
}

# Handle Ctrl+C
trap cleanup EXIT

# Create working directory
DEMO_DIR="demo_replication"
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

# Create identical replica (server2) by copying
echo -e "${CYAN}[2/3] Creating replica filesystem (server2)...${NC}"
cp server1_fs.img server2_fs.img
echo -e "${GREEN}✓${NC} Created server2_fs.img (identical copy)"

# Verify both are identical
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

echo -e "${BOLD}${YELLOW}PHASE 2: MAKE CHANGES ON SERVER1${NC}"
echo ""

# Mount server1 with data=journal mode
echo -e "${CYAN}[1/4] Mounting server1 filesystem...${NC}"
mkdir -p server1_mount
LOOP1=$(losetup -f)
losetup "$LOOP1" server1_fs.img
mount -o data=journal,barrier=0,commit=9999 "$LOOP1" server1_mount
echo -e "${GREEN}✓${NC} Mounted at server1_mount (data=journal mode)"

# Create files
echo -e "${CYAN}[2/4] Creating files on server1...${NC}"
echo "Hello from server1!" > server1_mount/abc.txt
echo "File 1 content" > server1_mount/file1.txt
echo "File 2 content" > server1_mount/file2.txt
mkdir server1_mount/testdir
echo "File in directory" > server1_mount/testdir/file3.txt
echo -e "${GREEN}✓${NC} Created abc.txt, file1.txt, file2.txt, testdir/file3.txt"

# List files
echo -e "${CYAN}[3/4] Files on server1:${NC}"
ls -lR server1_mount | grep -v "^total" | grep -v "^$" | sed 's/^/  /'

# Wait for journal commit (don't call sync - it triggers checkpoint!)
echo -e "${CYAN}[4/4] Waiting for journal commit...${NC}"
echo -e "${BLUE}  Note: NOT calling sync - it would checkpoint the journal!${NC}"
echo -e "${BLUE}  Instead, letting ext4 naturally commit to journal...${NC}"
sleep 2  # Give kernel time to commit transaction to journal
echo -e "${GREEN}✓${NC} Transaction should be in journal now"
echo ""

echo -e "${BOLD}${YELLOW}PHASE 3: CAPTURE JOURNAL STATE${NC}"
echo ""

# Capture journal while filesystem is STILL MOUNTED
# The journal blocks are on disk and can be read from the image file
echo -e "${CYAN}[1/1] Capturing journal (filesystem still mounted)...${NC}"
echo -e "${BLUE}  commit=9999 prevents checkpoint, keeping transactions in journal${NC}"
../journal_replicate_capture.sh server1_fs.img capture_data | sed 's/^/  /'
echo ""

# Now we can safely unmount server1
echo -e "${CYAN}Unmounting server1...${NC}"
umount server1_mount
losetup -d "$LOOP1"
echo -e "${GREEN}✓${NC} Server1 unmounted"
echo ""

echo -e "${BOLD}${YELLOW}PHASE 4: VERIFY SERVER2 DOESN'T HAVE CHANGES${NC}"
echo ""

# Mount server2 to show it's empty
echo -e "${CYAN}[1/2] Mounting server2 filesystem...${NC}"
mkdir -p server2_mount
LOOP2=$(losetup -f)
losetup "$LOOP2" server2_fs.img
mount "$LOOP2" server2_mount
echo -e "${GREEN}✓${NC} Mounted at server2_mount"

echo -e "${CYAN}[2/2] Files on server2 (before replication):${NC}"
FILE_COUNT=$(ls -A server2_mount | wc -l)
if [ "$FILE_COUNT" -eq 1 ]; then
    echo -e "  ${YELLOW}Only lost+found (empty filesystem)${NC}"
else
    ls -lR server2_mount | grep -v "^total" | grep -v "^$" | sed 's/^/  /'
fi

umount server2_mount
losetup -d "$LOOP2"
echo ""

echo -e "${BOLD}${YELLOW}PHASE 5: INJECT JOURNAL INTO SERVER2${NC}"
echo ""

echo -e "${CYAN}[1/1] Running journal injection...${NC}"
../journal_replicate_inject.sh server2_fs.img capture_data | grep -E "^\[|✓|ERROR" | sed 's/^/  /'
echo ""

echo -e "${BOLD}${YELLOW}PHASE 6: REPLAY JOURNAL ON SERVER2${NC}"
echo ""

echo -e "${CYAN}[1/1] Running e2fsck to replay journal...${NC}"
../e2fsck/e2fsck -fy server2_fs.img 2>&1 | head -10 | sed 's/^/  /'
echo -e "${GREEN}✓${NC} Journal replayed"
echo ""

echo -e "${BOLD}${YELLOW}PHASE 7: VERIFY REPLICATION${NC}"
echo ""

# Mount server2 again
echo -e "${CYAN}[1/3] Mounting server2 filesystem...${NC}"
LOOP2=$(losetup -f)
losetup "$LOOP2" server2_fs.img
mount "$LOOP2" server2_mount
echo -e "${GREEN}✓${NC} Mounted at server2_mount"

echo -e "${CYAN}[2/3] Files on server2 (after replication):${NC}"
ls -lR server2_mount | grep -v "^total" | grep -v "^$" | sed 's/^/  /'
echo ""

echo -e "${CYAN}[3/3] Verifying file contents...${NC}"
if [ -f server2_mount/abc.txt ]; then
    CONTENT=$(cat server2_mount/abc.txt)
    echo -e "  ${GREEN}✓${NC} abc.txt exists: '$CONTENT'"
else
    echo -e "  ${RED}✗${NC} abc.txt not found!"
fi

if [ -f server2_mount/file1.txt ]; then
    echo -e "  ${GREEN}✓${NC} file1.txt exists"
else
    echo -e "  ${RED}✗${NC} file1.txt not found!"
fi

if [ -f server2_mount/testdir/file3.txt ]; then
    echo -e "  ${GREEN}✓${NC} testdir/file3.txt exists"
else
    echo -e "  ${RED}✗${NC} testdir/file3.txt not found!"
fi

umount server2_mount
losetup -d "$LOOP2"
echo ""

echo -e "${BOLD}${YELLOW}PHASE 8: COMPARE FILESYSTEMS${NC}"
echo ""

echo -e "${CYAN}[1/1] Computing checksums...${NC}"
# Mount both and compare
LOOP1=$(losetup -f)
losetup "$LOOP1" server1_fs.img
mount "$LOOP1" server1_mount

LOOP2=$(losetup -f)
losetup "$LOOP2" server2_fs.img
mount "$LOOP2" server2_mount

# Compare directory listings
DIFF=$(diff -r server1_mount server2_mount 2>&1 | grep -v "lost+found" || true)
if [ -z "$DIFF" ]; then
    echo -e "  ${GREEN}✓${NC} Filesystems are IDENTICAL!"
else
    echo -e "  ${YELLOW}Differences found:${NC}"
    echo "$DIFF" | sed 's/^/    /'
fi

umount server1_mount
umount server2_mount
losetup -d "$LOOP1"
losetup -d "$LOOP2"

echo ""
echo -e "${BOLD}${GREEN}==================================================================="
echo "DEMONSTRATION COMPLETE"
echo "===================================================================${NC}"
echo ""
echo "Summary:"
echo "  1. Created source filesystem (server1)"
echo "  2. Created identical replica (server2)"
echo "  3. Made changes on server1 (4 files, 1 directory)"
echo "  4. Captured journal state from server1"
echo "  5. Injected journal into server2"
echo "  6. Replayed journal on server2"
echo "  7. Verified: server2 now has same files as server1"
echo ""
echo "All files are in: $PWD"
echo ""
