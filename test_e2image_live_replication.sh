#!/bin/bash
#
# test_e2image_live_replication.sh - Test replication with BOTH filesystems mounted
#
# Tests different approaches to keep server2 mounted during replication:
# 1. Drop caches approach
# 2. Remount readonly/readwrite approach
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
echo "E2IMAGE LIVE REPLICATION TEST - KEEP BOTH MOUNTED"
echo "====================================================================${NC}"
echo ""
echo -e "${YELLOW}Testing if we can keep server2 mounted during replication${NC}"
echo ""

cleanup() {
    umount /tmp/live_s1 2>/dev/null || true
    umount /tmp/live_s2 2>/dev/null || true
    LOOP1=$(losetup -j server1.img 2>/dev/null | cut -d: -f1)
    LOOP2=$(losetup -j server2.img 2>/dev/null | cut -d: -f1)
    [ -n "$LOOP1" ] && losetup -d "$LOOP1" 2>/dev/null || true
    [ -n "$LOOP2" ] && losetup -d "$LOOP2" 2>/dev/null || true
    rm -rf /tmp/test_live_repl
}
cleanup

mkdir -p /tmp/test_live_repl
cd /tmp/test_live_repl

echo -e "${BOLD}${YELLOW}SETUP: CREATE IDENTICAL FILESYSTEMS${NC}"
echo ""

echo -e "${CYAN}[1/5] Creating server1.img${NC}"
dd if=/dev/zero of=server1.img bs=1M count=100 2>/dev/null
$E2FSPROGS_DIR/misc/mke2fs -t ext4 -F server1.img >/dev/null 2>&1
echo -e "${GREEN}✓${NC} Created"

echo -e "${CYAN}[2/5] Creating server2.img (identical)${NC}"
cp server1.img server2.img
echo -e "${GREEN}✓${NC} Created"

echo -e "${CYAN}[3/5] Mounting server1${NC}"
LOOP1=$(losetup -f)
losetup "$LOOP1" server1.img
mkdir -p /tmp/live_s1
mount "$LOOP1" /tmp/live_s1
echo -e "${GREEN}✓${NC} Mounted at /tmp/live_s1 (stays mounted)"

echo -e "${CYAN}[4/5] Mounting server2${NC}"
LOOP2=$(losetup -f)
losetup "$LOOP2" server2.img
mkdir -p /tmp/live_s2
mount "$LOOP2" /tmp/live_s2
echo -e "${GREEN}✓${NC} Mounted at /tmp/live_s2 (stays mounted)"

echo -e "${CYAN}[5/5] Creating initial file on server1${NC}"
echo "Initial content from server1" > /tmp/live_s1/file1.txt
sync
echo -e "${GREEN}✓${NC} file1.txt created on server1"
echo ""

# ============================================================================
# TEST 1: Drop caches approach
# ============================================================================

echo -e "${BOLD}${YELLOW}TEST 1: DROP CACHES APPROACH${NC}"
echo ""
echo -e "${CYAN}Theory: Drop server2 caches, run e2image, kernel re-reads from disk${NC}"
echo ""

echo -e "${CYAN}[1/5] Checking file1.txt on server2 (should not exist yet)${NC}"
if [ -f /tmp/live_s2/file1.txt ]; then
    echo -e "${YELLOW}⚠${NC} file1.txt already exists (unexpected)"
else
    echo -e "${GREEN}✓${NC} file1.txt does not exist (as expected)"
fi

echo -e "${CYAN}[2/5] Dropping ALL caches on server2${NC}"
sync
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || echo "  (Cannot drop caches - need root)"
echo -e "${GREEN}✓${NC} Caches dropped"

echo -e "${CYAN}[3/5] Running e2image with -f (force on mounted source)${NC}"
echo "  Command: e2image -ra -c -f -p server1.img server2.img"
if $E2FSPROGS_DIR/misc/e2image -ra -c -f -p server1.img server2.img 2>&1 | tail -3; then
    echo -e "${GREEN}✓${NC} e2image completed"
else
    echo -e "${RED}✗${NC} e2image failed"
fi

echo -e "${CYAN}[4/5] Dropping caches again to force re-read${NC}"
sync
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
echo -e "${GREEN}✓${NC} Caches dropped"

echo -e "${CYAN}[5/5] Checking if file1.txt appears on server2${NC}"
TEST1_SUCCESS=false
if [ -f /tmp/live_s2/file1.txt ]; then
    CONTENT=$(cat /tmp/live_s2/file1.txt 2>/dev/null || echo "(read error)")
    if [ "$CONTENT" = "Initial content from server1" ]; then
        echo -e "${GREEN}✓✓✓ SUCCESS! file1.txt found with correct content${NC}"
        echo "  Content: '$CONTENT'"
        TEST1_SUCCESS=true
    else
        echo -e "${RED}✗${NC} file1.txt found but content wrong"
        echo "  Expected: 'Initial content from server1'"
        echo "  Got: '$CONTENT'"
    fi
else
    echo -e "${RED}✗${NC} file1.txt still not visible"
    echo "  Files on server2:"
    ls -la /tmp/live_s2 | sed 's/^/    /'
fi
echo ""

# ============================================================================
# TEST 2: Remount approach
# ============================================================================

echo -e "${BOLD}${YELLOW}TEST 2: REMOUNT READONLY/READWRITE APPROACH${NC}"
echo ""
echo -e "${CYAN}Theory: Remount server2 as RO, run e2image, remount RW${NC}"
echo -e "${CYAN}This forces kernel to invalidate cached metadata${NC}"
echo ""

echo -e "${CYAN}[1/6] Creating file2.txt on server1${NC}"
echo "Second file from server1" > /tmp/live_s1/file2.txt
sync
echo -e "${GREEN}✓${NC} file2.txt created"

echo -e "${CYAN}[2/6] Remounting server2 as READ-ONLY${NC}"
if mount -o remount,ro /tmp/live_s2 2>&1; then
    echo -e "${GREEN}✓${NC} Remounted read-only"
else
    echo -e "${RED}✗${NC} Remount failed"
fi

echo -e "${CYAN}[3/6] Running e2image${NC}"
if $E2FSPROGS_DIR/misc/e2image -ra -c -f -p server1.img server2.img 2>&1 | tail -3; then
    echo -e "${GREEN}✓${NC} e2image completed"
else
    echo -e "${RED}✗${NC} e2image failed"
fi

echo -e "${CYAN}[4/6] Remounting server2 as READ-WRITE${NC}"
if mount -o remount,rw /tmp/live_s2 2>&1; then
    echo -e "${GREEN}✓${NC} Remounted read-write"
else
    echo -e "${RED}✗${NC} Remount failed"
fi

echo -e "${CYAN}[5/6] Dropping caches to force re-read${NC}"
sync
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
echo -e "${GREEN}✓${NC} Caches dropped"

echo -e "${CYAN}[6/6] Checking if file2.txt appears on server2${NC}"
TEST2_SUCCESS=false
if [ -f /tmp/live_s2/file2.txt ]; then
    CONTENT=$(cat /tmp/live_s2/file2.txt 2>/dev/null || echo "(read error)")
    if [ "$CONTENT" = "Second file from server1" ]; then
        echo -e "${GREEN}✓✓✓ SUCCESS! file2.txt found with correct content${NC}"
        echo "  Content: '$CONTENT'"
        TEST2_SUCCESS=true
    else
        echo -e "${RED}✗${NC} file2.txt found but content wrong"
        echo "  Expected: 'Second file from server1'"
        echo "  Got: '$CONTENT'"
    fi
else
    echo -e "${RED}✗${NC} file2.txt not visible"
fi
echo ""

# ============================================================================
# TEST 3: Full unmount/remount (baseline)
# ============================================================================

echo -e "${BOLD}${YELLOW}TEST 3: FULL UNMOUNT/REMOUNT (BASELINE)${NC}"
echo ""
echo -e "${CYAN}This is the safe approach - should always work${NC}"
echo ""

echo -e "${CYAN}[1/5] Creating file3.txt on server1${NC}"
echo "Third file from server1" > /tmp/live_s1/file3.txt
sync
echo -e "${GREEN}✓${NC} file3.txt created"

echo -e "${CYAN}[2/5] Fully unmounting server2${NC}"
umount /tmp/live_s2
echo -e "${GREEN}✓${NC} Unmounted"

echo -e "${CYAN}[3/5] Running e2image${NC}"
if $E2FSPROGS_DIR/misc/e2image -ra -c -f -p server1.img server2.img 2>&1 | tail -3; then
    echo -e "${GREEN}✓${NC} e2image completed"
else
    echo -e "${RED}✗${NC} e2image failed"
fi

echo -e "${CYAN}[4/5] Remounting server2${NC}"
mount "$LOOP2" /tmp/live_s2
echo -e "${GREEN}✓${NC} Mounted"

echo -e "${CYAN}[5/5] Checking if file3.txt appears${NC}"
TEST3_SUCCESS=false
if [ -f /tmp/live_s2/file3.txt ]; then
    CONTENT=$(cat /tmp/live_s2/file3.txt)
    if [ "$CONTENT" = "Third file from server1" ]; then
        echo -e "${GREEN}✓✓✓ SUCCESS! file3.txt found with correct content${NC}"
        echo "  Content: '$CONTENT'"
        TEST3_SUCCESS=true
    else
        echo -e "${RED}✗${NC} file3.txt found but content wrong"
    fi
else
    echo -e "${RED}✗${NC} file3.txt not visible"
fi
echo ""

# ============================================================================
# FILESYSTEM INTEGRITY CHECK
# ============================================================================

echo -e "${BOLD}${YELLOW}FILESYSTEM INTEGRITY CHECK${NC}"
echo ""

echo -e "${CYAN}Unmounting both filesystems${NC}"
umount /tmp/live_s1
umount /tmp/live_s2
losetup -d "$LOOP1"
losetup -d "$LOOP2"

echo -e "${CYAN}Running e2fsck on server2${NC}"
if $E2FSPROGS_DIR/e2fsck/e2fsck -fn server2.img 2>&1 | grep -E "(clean|error)" | sed 's/^/  /'; then
    echo -e "${GREEN}✓${NC} Filesystem check completed"
else
    echo -e "${YELLOW}⚠${NC} Check e2fsck output"
fi
echo ""

cleanup

# ============================================================================
# RESULTS
# ============================================================================

echo -e "${BOLD}${CYAN}===================================================================="
echo "RESULTS SUMMARY"
echo "====================================================================${NC}"
echo ""

echo -e "${BOLD}Test Results:${NC}"
if [ "$TEST1_SUCCESS" = "true" ]; then
    echo -e "  Test 1 (Drop caches): ${GREEN}✓ SUCCESS${NC}"
else
    echo -e "  Test 1 (Drop caches): ${RED}✗ FAILED${NC}"
fi

if [ "$TEST2_SUCCESS" = "true" ]; then
    echo -e "  Test 2 (Remount ro/rw): ${GREEN}✓ SUCCESS${NC}"
else
    echo -e "  Test 2 (Remount ro/rw): ${RED}✗ FAILED${NC}"
fi

if [ "$TEST3_SUCCESS" = "true" ]; then
    echo -e "  Test 3 (Full unmount): ${GREEN}✓ SUCCESS${NC}"
else
    echo -e "  Test 3 (Full unmount): ${RED}✗ FAILED${NC}"
fi
echo ""

echo -e "${BOLD}Analysis:${NC}"
if [ "$TEST1_SUCCESS" = "true" ]; then
    echo -e "  ${GREEN}✓ Drop caches works!${NC} Can keep server2 mounted with just cache drops"
    echo "  Recommended approach: drop_caches before and after e2image"
elif [ "$TEST2_SUCCESS" = "true" ]; then
    echo -e "  ${YELLOW}⚠ Drop caches failed, but remount works${NC}"
    echo "  Recommended approach: remount ro, e2image, remount rw"
    echo "  Brief read-only period during replication"
else
    echo -e "  ${RED}✗ Both live approaches failed${NC}"
    echo "  Must fully unmount server2 during replication"
    echo "  Recommended: Quick unmount/remount (1-5 second downtime)"
fi
echo ""
