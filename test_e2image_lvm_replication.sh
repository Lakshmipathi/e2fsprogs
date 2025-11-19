#!/bin/bash
#
# test_e2image_lvm_replication.sh - Production-grade replication with LVM snapshots
#
# Uses LVM snapshots for zero-downtime replication:
# 1. Create snapshot of server2
# 2. Apply replication to snapshot (server2 stays online)
# 3. Atomically merge snapshot back
#
# This is the PRODUCTION approach for zero-downtime replication
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
echo "LVM SNAPSHOT-BASED REPLICATION (PRODUCTION APPROACH)"
echo "====================================================================${NC}"
echo ""
echo -e "${YELLOW}Zero-downtime replication using LVM snapshots${NC}"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}ERROR: This script requires root privileges for LVM operations${NC}"
    echo "Please run with: sudo $0"
    exit 1
fi

# Check if LVM tools are available
if ! command -v lvcreate &> /dev/null; then
    echo -e "${RED}ERROR: LVM tools not found${NC}"
    echo "Install with: apt-get install lvm2"
    exit 1
fi

cleanup() {
    # Clean up LVM volumes if they exist
    lvremove -f /dev/test_vg/server1_snap 2>/dev/null || true
    lvremove -f /dev/test_vg/server2_snap 2>/dev/null || true
    lvremove -f /dev/test_vg/server1 2>/dev/null || true
    lvremove -f /dev/test_vg/server2 2>/dev/null || true
    vgremove -f test_vg 2>/dev/null || true

    # Find and remove loop devices dynamically
    LOOP1=$(losetup -j lvm_pv1.img 2>/dev/null | cut -d: -f1)
    LOOP2=$(losetup -j lvm_pv2.img 2>/dev/null | cut -d: -f1)
    [ -n "$LOOP1" ] && pvremove -f "$LOOP1" 2>/dev/null || true
    [ -n "$LOOP2" ] && pvremove -f "$LOOP2" 2>/dev/null || true

    umount /tmp/lvm_s1 2>/dev/null || true
    umount /tmp/lvm_s2 2>/dev/null || true

    [ -n "$LOOP1" ] && losetup -d "$LOOP1" 2>/dev/null || true
    [ -n "$LOOP2" ] && losetup -d "$LOOP2" 2>/dev/null || true

    rm -rf /tmp/test_lvm_repl
}
cleanup

mkdir -p /tmp/test_lvm_repl
cd /tmp/test_lvm_repl

echo -e "${BOLD}${YELLOW}PHASE 1: SETUP LVM ENVIRONMENT${NC}"
echo ""

echo -e "${CYAN}[1/8] Creating backing files for LVM${NC}"
dd if=/dev/zero of=lvm_pv1.img bs=1M count=200 2>/dev/null
dd if=/dev/zero of=lvm_pv2.img bs=1M count=200 2>/dev/null
echo -e "${GREEN}✓${NC} Backing files created (200MB each)"

echo -e "${CYAN}[2/8] Setting up loop devices${NC}"
LOOP_PV1=$(losetup -f --show lvm_pv1.img)
sleep 0.5  # Brief delay for device to settle
LOOP_PV2=$(losetup -f --show lvm_pv2.img)
echo -e "${GREEN}✓${NC} Loop devices: $LOOP_PV1, $LOOP_PV2"

echo -e "${CYAN}[3/8] Creating LVM physical volumes${NC}"
pvcreate $LOOP_PV1 >/dev/null 2>&1
pvcreate $LOOP_PV2 >/dev/null 2>&1
echo -e "${GREEN}✓${NC} Physical volumes created"

echo -e "${CYAN}[4/8] Creating volume group 'test_vg'${NC}"
vgcreate test_vg $LOOP_PV1 $LOOP_PV2 >/dev/null 2>&1
echo -e "${GREEN}✓${NC} Volume group created"

echo -e "${CYAN}[5/8] Creating logical volumes${NC}"
lvcreate -L 80M -n server1 test_vg >/dev/null 2>&1
lvcreate -L 80M -n server2 test_vg >/dev/null 2>&1
echo -e "${GREEN}✓${NC} Logical volumes: /dev/test_vg/server1, /dev/test_vg/server2"

echo -e "${CYAN}[6/8] Creating ext4 filesystems${NC}"
$E2FSPROGS_DIR/misc/mke2fs -t ext4 -F /dev/test_vg/server1 >/dev/null 2>&1
$E2FSPROGS_DIR/misc/mke2fs -t ext4 -F /dev/test_vg/server2 >/dev/null 2>&1
echo -e "${GREEN}✓${NC} Filesystems created"

echo -e "${CYAN}[7/8] Mounting server1${NC}"
mkdir -p /tmp/lvm_s1
mount /dev/test_vg/server1 /tmp/lvm_s1
echo -e "${GREEN}✓${NC} server1 mounted at /tmp/lvm_s1"

echo -e "${CYAN}[8/8] Mounting server2${NC}"
mkdir -p /tmp/lvm_s2
mount /dev/test_vg/server2 /tmp/lvm_s2
echo -e "${GREEN}✓${NC} server2 mounted at /tmp/lvm_s2"
echo ""

echo -e "${BOLD}${YELLOW}PHASE 2: CREATE INITIAL DATA${NC}"
echo ""

echo -e "${CYAN}[1/2] Creating file1.txt on server1${NC}"
echo "Initial content from server1" > /tmp/lvm_s1/file1.txt
sync
echo -e "${GREEN}✓${NC} file1.txt created"

echo -e "${CYAN}[2/2] Replicating initial state to server2${NC}"
# Initial full sync - unmount server2 for this
umount /tmp/lvm_s2
$E2FSPROGS_DIR/misc/e2image -ra -c -f /dev/test_vg/server1 /dev/test_vg/server2 2>&1 | tail -2
# Run e2fsck to ensure filesystem is consistent after e2image
# e2fsck returns 0 (no errors), 1 (errors fixed), or 2 (errors fixed, reboot suggested)
$E2FSPROGS_DIR/e2fsck/e2fsck -fy /dev/test_vg/server2 >/dev/null 2>&1 || [ $? -le 2 ]
mount /dev/test_vg/server2 /tmp/lvm_s2
echo -e "${GREEN}✓${NC} Initial sync complete"

# Verify
if [ -f /tmp/lvm_s2/file1.txt ]; then
    echo -e "${GREEN}✓${NC} file1.txt exists on server2"
else
    echo -e "${RED}✗${NC} Initial sync failed"
    exit 1
fi
echo ""

echo -e "${BOLD}${YELLOW}PHASE 3: ZERO-DOWNTIME INCREMENTAL REPLICATION${NC}"
echo ""
echo -e "${CYAN}This simulates production: server2 stays mounted and online${NC}"
echo ""

echo -e "${CYAN}[1/7] Creating file2.txt on server1 (simulates new data)${NC}"
echo "Second file - created after initial sync" > /tmp/lvm_s1/file2.txt
sync
echo -e "${GREEN}✓${NC} file2.txt created on server1"

echo -e "${CYAN}[2/7] Creating LVM snapshot of server2${NC}"
echo "  This allows us to work on a snapshot while server2 stays online"
lvcreate -s -L 20M -n server2_snap /dev/test_vg/server2 >/dev/null 2>&1
echo -e "${GREEN}✓${NC} Snapshot created: /dev/test_vg/server2_snap"

echo -e "${CYAN}[3/7] Verifying server2 is still online${NC}"
if [ -f /tmp/lvm_s2/file1.txt ]; then
    echo -e "${GREEN}✓${NC} server2 accessible (zero downtime!)"
else
    echo -e "${RED}✗${NC} server2 offline"
fi

echo -e "${CYAN}[4/7] Replicating to snapshot (server2 stays online)${NC}"
echo "  Command: e2image -ra -f /dev/test_vg/server1 /dev/test_vg/server2_snap"
echo "  Note: Not using -c flag with snapshots (compare mode doesn't work with COW)"
$E2FSPROGS_DIR/misc/e2image -ra -f /dev/test_vg/server1 /dev/test_vg/server2_snap 2>&1 | tail -2
# Run e2fsck on snapshot to ensure consistency
$E2FSPROGS_DIR/e2fsck/e2fsck -fy /dev/test_vg/server2_snap >/dev/null 2>&1 || [ $? -le 2 ]
echo -e "${GREEN}✓${NC} Replication to snapshot complete"

echo -e "${CYAN}[5/7] Verifying server2 still online during replication${NC}"
if [ -f /tmp/lvm_s2/file1.txt ]; then
    echo -e "${GREEN}✓${NC} server2 remained online throughout replication"
else
    echo -e "${YELLOW}⚠${NC} server2 became unavailable"
fi

echo -e "${CYAN}[6/7] Unmounting server2 briefly for atomic merge${NC}"
umount /tmp/lvm_s2
echo -e "${GREEN}✓${NC} Unmounted"

echo -e "${CYAN}[7/7] Merging snapshot atomically${NC}"
echo "  This is the only brief downtime (milliseconds)"
lvconvert --merge /dev/test_vg/server2_snap
# Wait for merge to complete
sleep 2
echo -e "${GREEN}✓${NC} Snapshot merged"

echo ""

echo -e "${BOLD}${YELLOW}PHASE 4: VERIFY REPLICATION${NC}"
echo ""

echo -e "${CYAN}[1/3] Remounting server2${NC}"
mount /dev/test_vg/server2 /tmp/lvm_s2
echo -e "${GREEN}✓${NC} Mounted"

echo -e "${CYAN}[2/3] Checking for file2.txt${NC}"
SUCCESS=false
if [ -f /tmp/lvm_s2/file2.txt ]; then
    CONTENT=$(cat /tmp/lvm_s2/file2.txt)
    if [ "$CONTENT" = "Second file - created after initial sync" ]; then
        echo -e "${GREEN}✓✓✓ SUCCESS! file2.txt replicated with correct content${NC}"
        echo "  Content: '$CONTENT'"
        SUCCESS=true
    else
        echo -e "${RED}✗${NC} file2.txt has wrong content"
    fi
else
    echo -e "${RED}✗${NC} file2.txt not found"
fi

echo -e "${CYAN}[3/3] Verifying file1.txt still exists${NC}"
if [ -f /tmp/lvm_s2/file1.txt ]; then
    echo -e "${GREEN}✓${NC} file1.txt still present"
else
    echo -e "${RED}✗${NC} file1.txt disappeared"
fi
echo ""

echo -e "${BOLD}${YELLOW}PHASE 5: DEMONSTRATE CONTINUOUS OPERATION${NC}"
echo ""

echo -e "${CYAN}[1/4] Creating file3.txt on server1${NC}"
echo "Third file - continuous updates" > /tmp/lvm_s1/file3.txt
sync
echo -e "${GREEN}✓${NC} file3.txt created"

echo -e "${CYAN}[2/4] Snapshot → Replicate → Merge (all automated)${NC}"
lvcreate -s -L 20M -n server2_snap /dev/test_vg/server2 >/dev/null 2>&1
$E2FSPROGS_DIR/misc/e2image -ra -f /dev/test_vg/server1 /dev/test_vg/server2_snap 2>&1 | tail -1
$E2FSPROGS_DIR/e2fsck/e2fsck -fy /dev/test_vg/server2_snap >/dev/null 2>&1 || [ $? -le 2 ]
umount /tmp/lvm_s2
lvconvert --merge /dev/test_vg/server2_snap
sleep 2
mount /dev/test_vg/server2 /tmp/lvm_s2
echo -e "${GREEN}✓${NC} Automated replication cycle complete"

echo -e "${CYAN}[3/4] Checking file3.txt${NC}"
if [ -f /tmp/lvm_s2/file3.txt ]; then
    echo -e "${GREEN}✓${NC} file3.txt replicated"
else
    echo -e "${RED}✗${NC} file3.txt not found"
fi

echo -e "${CYAN}[4/4] Listing all files on server2${NC}"
echo "  Files:"
ls -lh /tmp/lvm_s2/*.txt 2>/dev/null | sed 's/^/    /'
echo ""

cleanup

echo -e "${BOLD}${CYAN}===================================================================="
echo "RESULTS SUMMARY"
echo "====================================================================${NC}"
echo ""

if [ "$SUCCESS" = "true" ]; then
    echo -e "${GREEN}✓ SUCCESS: LVM snapshot-based replication WORKS!${NC}"
    echo ""
    echo -e "${BOLD}Key advantages:${NC}"
    echo "  1. Near-zero downtime (only milliseconds for merge)"
    echo "  2. Server2 stays online during replication"
    echo "  3. Atomic snapshot merge ensures consistency"
    echo "  4. Can be automated with cron/systemd timer"
    echo "  5. Safe rollback if replication fails (keep snapshot)"
    echo ""
    echo -e "${BOLD}Production workflow:${NC}"
    echo "  1. lvcreate -s -L <size> -n server2_snap /dev/vg/server2"
    echo "  2. e2image -ra -f /dev/vg/server1 /dev/vg/server2_snap  (no -c with snapshots!)"
    echo "  3. e2fsck -fy /dev/vg/server2_snap  (ensure consistency!)"
    echo "  4. umount /mnt/server2 (brief downtime starts)"
    echo "  5. lvconvert --merge /dev/vg/server2_snap"
    echo "  6. mount /mnt/server2 (downtime ends - typically <1 second)"
    echo ""
    echo -e "${BOLD}Automation:${NC}"
    echo "  - Run every N minutes/hours via cron"
    echo "  - Monitor with scripts"
    echo "  - Alert on failures"
    echo "  - Keep failed snapshots for debugging"
else
    echo -e "${RED}✗ FAILED: LVM replication did not work${NC}"
fi
echo ""
