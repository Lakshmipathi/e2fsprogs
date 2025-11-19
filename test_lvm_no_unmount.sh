#!/bin/bash
#
# test_lvm_no_unmount.sh - Test e2image with NO unmount (3x sync approach)
#
# Tests user's hypothesis: 3x sync + e2image -f might work without unmounting
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

echo -e "${BOLD}${CYAN}====================================================================="
echo "LVM TEST: NO UNMOUNT (3x sync + e2image -f)"
echo "====================================================================${NC}"
echo ""
echo -e "${YELLOW}Testing if 3x sync + e2image -f works without unmounting${NC}"
echo ""

cleanup() {
    lvremove -f /dev/test_vg/server1 2>/dev/null || true
    lvremove -f /dev/test_vg/server2 2>/dev/null || true
    lvremove -f /dev/test_vg/server2_snap 2>/dev/null || true
    vgremove -f test_vg 2>/dev/null || true
    LOOP1=$(losetup -j lvm_pv1.img 2>/dev/null | cut -d: -f1)
    LOOP2=$(losetup -j lvm_pv2.img 2>/dev/null | cut -d: -f1)
    [ -n "$LOOP1" ] && pvremove -f "$LOOP1" 2>/dev/null || true
    [ -n "$LOOP2" ] && pvremove -f "$LOOP2" 2>/dev/null || true
    umount /tmp/lvm_s1 2>/dev/null || true
    umount /tmp/lvm_s2 2>/dev/null || true
    umount /tmp/lvm_snap_check 2>/dev/null || true
    [ -n "$LOOP1" ] && losetup -d "$LOOP1" 2>/dev/null || true
    [ -n "$LOOP2" ] && losetup -d "$LOOP2" 2>/dev/null || true
    rm -rf /tmp/test_lvm_no_unmount
}
cleanup

mkdir -p /tmp/test_lvm_no_unmount
cd /tmp/test_lvm_no_unmount

echo -e "${BOLD}${YELLOW}SETUP LVM${NC}"
echo ""
dd if=/dev/zero of=lvm_pv1.img bs=1M count=200 2>/dev/null
dd if=/dev/zero of=lvm_pv2.img bs=1M count=200 2>/dev/null
LOOP_PV1=$(losetup -f --show lvm_pv1.img)
sleep 0.5
LOOP_PV2=$(losetup -f --show lvm_pv2.img)
pvcreate $LOOP_PV1 $LOOP_PV2 >/dev/null 2>&1
vgcreate test_vg $LOOP_PV1 $LOOP_PV2 >/dev/null 2>&1
lvcreate -L 80M -n server1 test_vg >/dev/null 2>&1
lvcreate -L 80M -n server2 test_vg >/dev/null 2>&1
$E2FSPROGS_DIR/misc/mke2fs -t ext4 -F /dev/test_vg/server1 >/dev/null 2>&1
$E2FSPROGS_DIR/misc/mke2fs -t ext4 -F /dev/test_vg/server2 >/dev/null 2>&1
mkdir -p /tmp/lvm_s1 /tmp/lvm_s2
mount /dev/test_vg/server1 /tmp/lvm_s1
mount /dev/test_vg/server2 /tmp/lvm_s2
echo -e "${GREEN}✓${NC} LVM setup complete"
echo ""

echo -e "${BOLD}${YELLOW}PHASE 1: INITIAL SYNC (both mounted)${NC}"
echo ""

echo "Initial file" > /tmp/lvm_s1/file1.txt
sync; sync; sync
echo -e "${CYAN}Triple sync done${NC}"

echo -e "${CYAN}Running e2image -ra -f (both mounted, no unmount!)${NC}"
$E2FSPROGS_DIR/misc/e2image -ra -f /dev/test_vg/server1 /dev/test_vg/server2 2>&1 | tail -2
$E2FSPROGS_DIR/e2fsck/e2fsck -fy /dev/test_vg/server2 >/dev/null 2>&1 || [ $? -le 2 ]

if [ -f /tmp/lvm_s2/file1.txt ]; then
    echo -e "${GREEN}✓${NC} file1.txt replicated"
else
    echo -e "${RED}✗${NC} file1.txt missing"
fi
echo ""

echo -e "${BOLD}${YELLOW}PHASE 2: INCREMENTAL SYNC (NO UNMOUNT!)${NC}"
echo ""

echo -e "${CYAN}[1/5] Creating file2.txt (both mounted)${NC}"
echo "Second file - incremental" > /tmp/lvm_s1/file2.txt
echo -e "${GREEN}✓${NC} Created"

echo -e "${CYAN}[2/5] Triple sync${NC}"
sync
echo "  Sync 1"
sync
echo "  Sync 2"
sync
echo "  Sync 3"
echo -e "${GREEN}✓${NC} Done"

echo -e "${CYAN}[3/5] Verify file2.txt on server1${NC}"
if [ -f /tmp/lvm_s1/file2.txt ]; then
    CONTENT=$(cat /tmp/lvm_s1/file2.txt)
    echo -e "  ${GREEN}✓${NC} file2.txt EXISTS on server1"
    echo "  Content: '$CONTENT'"
else
    echo -e "  ${RED}✗${NC} MISSING"
fi

echo -e "${CYAN}[4/5] Creating snapshot${NC}"
lvcreate -s -L 20M -n server2_snap /dev/test_vg/server2 >/dev/null 2>&1
echo -e "${GREEN}✓${NC} Snapshot created"

echo -e "${CYAN}[5/5] e2image -ra -f to snapshot (NO UNMOUNT!)${NC}"
$E2FSPROGS_DIR/misc/e2image -ra -f /dev/test_vg/server1 /dev/test_vg/server2_snap 2>&1 | tail -2
$E2FSPROGS_DIR/e2fsck/e2fsck -fy /dev/test_vg/server2_snap >/dev/null 2>&1 || [ $? -le 2 ]
echo -e "${GREEN}✓${NC} Replication complete"
echo ""

echo -e "${BOLD}${YELLOW}VERIFY${NC}"
echo ""

mkdir -p /tmp/lvm_snap_check
mount /dev/test_vg/server2_snap /tmp/lvm_snap_check
echo "Files on snapshot:"
ls -la /tmp/lvm_snap_check/*.txt 2>/dev/null | sed 's/^/  /' || echo "  (no files)"

SUCCESS=false
if [ -f /tmp/lvm_snap_check/file2.txt ]; then
    CONTENT=$(cat /tmp/lvm_snap_check/file2.txt)
    if [ "$CONTENT" = "Second file - incremental" ]; then
        echo -e "${GREEN}✓✓✓ SUCCESS! file2.txt found with correct content!${NC}"
        echo "Content: '$CONTENT'"
        SUCCESS=true
    fi
else
    echo -e "${RED}✗ file2.txt NOT found${NC}"
fi

umount /tmp/lvm_snap_check
cleanup

echo ""
echo -e "${BOLD}${CYAN}====================================================================="
echo "RESULT"
echo "====================================================================${NC}"
echo ""

if [ "$SUCCESS" = "true" ]; then
    echo -e "${GREEN}✓ SUCCESS: Your approach WORKS!${NC}"
    echo ""
    echo "3x sync + e2image -f (no unmount) successfully replicates files!"
    echo ""
    echo "Production workflow:"
    echo "  1. sync; sync; sync"
    echo "  2. lvcreate snapshot"
    echo "  3. e2image -ra -f source snapshot"
    echo "  4. e2fsck snapshot"
    echo "  5. merge snapshot"
    echo ""
    echo "TRUE zero-downtime - no unmount/remount needed!"
else
    echo -e "${RED}✗ FAILED: Doesn't work even with triple sync${NC}"
    echo ""
    echo "Remount ro/rw approach is still needed."
fi
echo ""
