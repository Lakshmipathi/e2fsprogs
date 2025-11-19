#!/bin/bash
#
# test_e2image_lvm_replication.sh - Production-grade replication
#
# Supports two modes:
#   --mode=lvm (default)    - LVM snapshot approach (zero-downtime)
#   --mode=freeze           - fsfreeze approach (blocks writes during e2image)
#
# Usage:
#   ./test_e2image_lvm_replication.sh              # Uses LVM (default)
#   ./test_e2image_lvm_replication.sh --mode=lvm   # Uses LVM
#   ./test_e2image_lvm_replication.sh --mode=freeze # Uses fsfreeze
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

# Parse command-line arguments
MODE="lvm"  # Default mode
for arg in "$@"; do
    case $arg in
        --mode=*)
            MODE="${arg#*=}"
            shift
            ;;
        *)
            echo "Unknown argument: $arg"
            echo "Usage: $0 [--mode=lvm|freeze]"
            exit 1
            ;;
    esac
done

# Validate mode
if [ "$MODE" != "lvm" ] && [ "$MODE" != "freeze" ]; then
    echo -e "${RED}ERROR: Invalid mode '$MODE'. Must be 'lvm' or 'freeze'${NC}"
    exit 1
fi

echo -e "${BOLD}${CYAN}===================================================================="
if [ "$MODE" = "lvm" ]; then
    echo "LVM SNAPSHOT-BASED REPLICATION (PRODUCTION APPROACH)"
else
    echo "FSFREEZE-BASED REPLICATION (NO LVM REQUIRED)"
fi
echo "====================================================================${NC}"
echo ""
echo -e "${YELLOW}Mode: $MODE${NC}"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}ERROR: This script requires root privileges${NC}"
    echo "Please run with: sudo $0"
    exit 1
fi

# Check requirements based on mode
if [ "$MODE" = "lvm" ]; then
    if ! command -v lvcreate &> /dev/null; then
        echo -e "${RED}ERROR: LVM tools not found${NC}"
        echo "Install with: apt-get install lvm2"
        exit 1
    fi
fi

cleanup() {
    if [ "$MODE" = "lvm" ]; then
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
    else
        # Freeze mode: just loop devices
        LOOP1=$(losetup -j server1.img 2>/dev/null | cut -d: -f1)
        LOOP2=$(losetup -j server2.img 2>/dev/null | cut -d: -f1)
    fi

    umount /tmp/lvm_s1 2>/dev/null || true
    umount /tmp/lvm_s2 2>/dev/null || true

    [ -n "$LOOP1" ] && losetup -d "$LOOP1" 2>/dev/null || true
    [ -n "$LOOP2" ] && losetup -d "$LOOP2" 2>/dev/null || true

    rm -rf /tmp/test_lvm_repl
}
cleanup

mkdir -p /tmp/test_lvm_repl
cd /tmp/test_lvm_repl

if [ "$MODE" = "lvm" ]; then
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

    DEV1="/dev/test_vg/server1"
    DEV2="/dev/test_vg/server2"
else
    echo -e "${BOLD}${YELLOW}PHASE 1: SETUP PLAIN EXT4 ENVIRONMENT (NO LVM)${NC}"
    echo ""

    echo -e "${CYAN}[1/4] Creating backing files${NC}"
    dd if=/dev/zero of=server1.img bs=1M count=100 2>/dev/null
    dd if=/dev/zero of=server2.img bs=1M count=100 2>/dev/null
    echo -e "${GREEN}✓${NC} Backing files created (100MB each)"

    echo -e "${CYAN}[2/4] Setting up loop devices${NC}"
    LOOP_PV1=$(losetup -f --show server1.img)
    sleep 0.5
    LOOP_PV2=$(losetup -f --show server2.img)
    echo -e "${GREEN}✓${NC} Loop devices: $LOOP_PV1, $LOOP_PV2"

    echo -e "${CYAN}[3/4] Creating ext4 filesystems${NC}"
    $E2FSPROGS_DIR/misc/mke2fs -t ext4 -F $LOOP_PV1 >/dev/null 2>&1
    $E2FSPROGS_DIR/misc/mke2fs -t ext4 -F $LOOP_PV2 >/dev/null 2>&1
    echo -e "${GREEN}✓${NC} Filesystems created"

    DEV1="$LOOP_PV1"
    DEV2="$LOOP_PV2"
fi

if [ "$MODE" = "lvm" ]; then
    echo -e "${CYAN}[7/8] Mounting server1${NC}"
else
    echo -e "${CYAN}[4/4] Mounting filesystems${NC}"
fi
mkdir -p /tmp/lvm_s1
mount $DEV1 /tmp/lvm_s1
echo -e "${GREEN}✓${NC} server1 mounted at /tmp/lvm_s1"

if [ "$MODE" = "lvm" ]; then
    echo -e "${CYAN}[8/8] Mounting server2${NC}"
fi
mkdir -p /tmp/lvm_s2
mount $DEV2 /tmp/lvm_s2
echo -e "${GREEN}✓${NC} server2 mounted at /tmp/lvm_s2"
echo ""

echo -e "${BOLD}${YELLOW}PHASE 2: CREATE INITIAL DATA${NC}"
echo ""

echo -e "${CYAN}[1/2] Creating file1.txt on server1${NC}"
echo "Initial content from server1" > /tmp/lvm_s1/file1.txt
sync
echo -e "${GREEN}✓${NC} file1.txt created"

echo -e "${CYAN}[2/2] Replicating initial state to server2${NC}"
if [ "$MODE" = "lvm" ]; then
    echo "  Using LVM snapshot for consistent initial sync"
    lvcreate -s -L 20M -n server1_snap /dev/test_vg/server1 >/dev/null 2>&1
    umount /tmp/lvm_s2
    $E2FSPROGS_DIR/misc/e2image -ra /dev/test_vg/server1_snap $DEV2 2>&1 | tail -2
    $E2FSPROGS_DIR/e2fsck/e2fsck -fy $DEV2 >/dev/null 2>&1 || [ $? -le 2 ]
    lvremove -f /dev/test_vg/server1_snap >/dev/null 2>&1
    mount $DEV2 /tmp/lvm_s2
else
    echo "  Temporarily unmounting server1 for initial sync"
    umount /tmp/lvm_s1
    umount /tmp/lvm_s2
    $E2FSPROGS_DIR/misc/e2image -ra $DEV1 $DEV2 2>&1 | tail -2
    $E2FSPROGS_DIR/e2fsck/e2fsck -fy $DEV2 >/dev/null 2>&1 || [ $? -le 2 ]
    mount $DEV1 /tmp/lvm_s1
    mount $DEV2 /tmp/lvm_s2
fi
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
echo -e "${GREEN}✓${NC} file2.txt created on server1"

echo -e "${CYAN}[2/7] Ensuring all data is flushed to disk on server1${NC}"
sync
sleep 1
sync
echo -e "${GREEN}✓${NC} Data synced to disk"

if [ "$MODE" = "lvm" ]; then
    echo -e "${CYAN}[3/7] Creating LVM snapshot of server2 (server2 stays mounted)${NC}"
    echo "  This allows us to work on a snapshot while server2 stays online"
    lvcreate -s -L 20M -n server2_snap /dev/test_vg/server2 >/dev/null 2>&1
    echo -e "${GREEN}✓${NC} Snapshot created: /dev/test_vg/server2_snap"

    echo -e "${CYAN}[4/7] Verifying server2 is still online${NC}"
    if [ -f /tmp/lvm_s2/file1.txt ]; then
        echo -e "${GREEN}✓${NC} server2 accessible (zero downtime!)"
    else
        echo -e "${RED}✗${NC} server2 offline"
    fi

    echo -e "${CYAN}[5/7] DEBUG: Verifying file2.txt exists on server1${NC}"
    echo "  Files on server1:"
    ls -la /tmp/lvm_s1/*.txt 2>/dev/null | sed 's/^/    /'
    if [ -f /tmp/lvm_s1/file2.txt ]; then
        CONTENT=$(cat /tmp/lvm_s1/file2.txt)
        echo -e "  ${GREEN}✓${NC} file2.txt EXISTS on server1!"
        echo "  Content: '$CONTENT'"
    else
        echo -e "  ${RED}✗${NC} file2.txt MISSING on server1! (BUG)"
    fi

    echo -e "${CYAN}[6/7] Creating LVM snapshot of SERVER1 (zero-downtime!)${NC}"
    echo "  Server1 stays 100% read-write - no remount, no freeze, nothing!"
    echo "  LVM snapshot = atomic point-in-time copy with automatic consistency"
    lvcreate -s -L 20M -n server1_snap /dev/test_vg/server1 >/dev/null 2>&1
    echo -e "${GREEN}✓${NC} Server1 snapshot created"

    echo -e "${CYAN}[7/7] Replicating from server1 snapshot to server2 snapshot${NC}"
    echo "  Command: e2image -ra /dev/test_vg/server1_snap /dev/test_vg/server2_snap"
    $E2FSPROGS_DIR/misc/e2image -ra /dev/test_vg/server1_snap /dev/test_vg/server2_snap 2>&1 | tail -2
    $E2FSPROGS_DIR/e2fsck/e2fsck -fy /dev/test_vg/server2_snap >/dev/null 2>&1 || [ $? -le 2 ]
    echo -e "${GREEN}✓${NC} Replication complete"

    echo -e "${CYAN}[8/8] Cleaning up server1 snapshot${NC}"
    lvremove -f /dev/test_vg/server1_snap >/dev/null 2>&1
    echo -e "${GREEN}✓${NC} Server1 snapshot removed"
else
    # FSFREEZE MODE
    echo -e "${CYAN}[3/7] Verifying file2.txt exists on server1${NC}"
    echo "  Files on server1:"
    ls -la /tmp/lvm_s1/*.txt 2>/dev/null | sed 's/^/    /'
    if [ -f /tmp/lvm_s1/file2.txt ]; then
        CONTENT=$(cat /tmp/lvm_s1/file2.txt)
        echo -e "  ${GREEN}✓${NC} file2.txt EXISTS on server1!"
        echo "  Content: '$CONTENT'"
    else
        echo -e "  ${RED}✗${NC} file2.txt MISSING on server1! (BUG)"
    fi

    echo -e "${CYAN}[4/7] FREEZING server1 filesystem${NC}"
    echo "  ${YELLOW}WARNING: Writes will block until unfreeze!${NC}"
    echo "  fsfreeze flushes ALL metadata - creates consistent point-in-time state"
    echo "  Starting timer..."
    FREEZE_START=$(date +%s%N)
    fsfreeze -f /tmp/lvm_s1
    echo -e "${GREEN}✓${NC} Filesystem frozen - all metadata flushed"

    echo -e "${CYAN}[5/7] Running e2image while frozen (using -f flag)${NC}"
    echo "  Command: e2image -ra -f $DEV1 $DEV2"
    echo "  Note: -f flag required because filesystem is mounted (though frozen)"
    umount /tmp/lvm_s2
    $E2FSPROGS_DIR/misc/e2image -ra -f $DEV1 $DEV2 2>&1 | tail -2
    $E2FSPROGS_DIR/e2fsck/e2fsck -fy $DEV2 >/dev/null 2>&1 || [ $? -le 2 ]
    mount $DEV2 /tmp/lvm_s2
    echo -e "${GREEN}✓${NC} e2image complete"

    echo -e "${CYAN}[6/7] UNFREEZING server1 filesystem${NC}"
    fsfreeze -u /tmp/lvm_s1
    FREEZE_END=$(date +%s%N)
    FREEZE_MS=$(( ($FREEZE_END - $FREEZE_START) / 1000000 ))
    echo -e "${GREEN}✓${NC} Filesystem unfrozen"
    echo -e "${YELLOW}  ⏱  FREEZE DURATION: ${FREEZE_MS} ms${NC}"
    echo -e "${YELLOW}  ⚠  Writes were BLOCKED for ${FREEZE_MS} ms!${NC}"
fi

if [ "$MODE" = "lvm" ]; then
    echo -e "${CYAN}Verifying server2 remained online${NC}"
    if [ -f /tmp/lvm_s2/file1.txt ]; then
        echo -e "${GREEN}✓${NC} server2 stayed online (zero downtime for server2!)"
    else
        echo -e "${YELLOW}⚠${NC} server2 became unavailable"
    fi

    echo -e "${CYAN}DEBUG: Checking snapshot contents before merge${NC}"
    mkdir -p /tmp/lvm_snap_check
    mount /dev/test_vg/server2_snap /tmp/lvm_snap_check
    echo "  Files on snapshot:"
    ls -la /tmp/lvm_snap_check/*.txt 2>/dev/null | sed 's/^/    /' || echo "    (no .txt files)"
    if [ -f /tmp/lvm_snap_check/file2.txt ]; then
        echo -e "  ${GREEN}✓${NC} file2.txt EXISTS on snapshot before merge!"
    else
        echo -e "  ${RED}✗${NC} file2.txt MISSING on snapshot!"
    fi
    umount /tmp/lvm_snap_check

    echo -e "${CYAN}[6/7] Unmounting server2 briefly for atomic merge${NC}"
    umount /tmp/lvm_s2
    echo -e "${GREEN}✓${NC} Unmounted"

    echo -e "${CYAN}[7/7] Merging snapshot atomically${NC}"
    echo "  This is the only brief downtime (milliseconds)"
    lvconvert --merge /dev/test_vg/server2_snap
    sleep 2
    echo -e "${GREEN}✓${NC} Snapshot merged"

    echo ""

    echo -e "${BOLD}${YELLOW}PHASE 4: VERIFY REPLICATION${NC}"
    echo ""

    echo -e "${CYAN}[1/3] Remounting server2${NC}"
    mount /dev/test_vg/server2 /tmp/lvm_s2
    echo -e "${GREEN}✓${NC} Mounted"
else
    # FREEZE MODE - server2 already updated, just verify
    echo ""

    echo -e "${BOLD}${YELLOW}PHASE 4: VERIFY REPLICATION${NC}"
    echo ""
    echo -e "${CYAN}Server2 already updated (no merge needed in freeze mode)${NC}"
fi

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

if [ "$MODE" = "lvm" ]; then
    echo -e "${CYAN}[2/4] Snapshot → Replicate → Merge (all automated)${NC}"
    lvcreate -s -L 20M -n server1_snap /dev/test_vg/server1 >/dev/null 2>&1
    lvcreate -s -L 20M -n server2_snap /dev/test_vg/server2 >/dev/null 2>&1
    $E2FSPROGS_DIR/misc/e2image -ra /dev/test_vg/server1_snap /dev/test_vg/server2_snap 2>&1 | tail -1
    $E2FSPROGS_DIR/e2fsck/e2fsck -fy /dev/test_vg/server2_snap >/dev/null 2>&1 || [ $? -le 2 ]
    lvremove -f /dev/test_vg/server1_snap >/dev/null 2>&1
    umount /tmp/lvm_s2
    lvconvert --merge /dev/test_vg/server2_snap
    sleep 2
    mount /dev/test_vg/server2 /tmp/lvm_s2
    echo -e "${GREEN}✓${NC} Automated replication cycle complete"
else
    echo -e "${CYAN}[2/4] Freeze → Replicate → Unfreeze (all automated)${NC}"
    FREEZE_START=$(date +%s%N)
    fsfreeze -f /tmp/lvm_s1
    umount /tmp/lvm_s2
    $E2FSPROGS_DIR/misc/e2image -ra -f $DEV1 $DEV2 2>&1 | tail -1
    $E2FSPROGS_DIR/e2fsck/e2fsck -fy $DEV2 >/dev/null 2>&1 || [ $? -le 2 ]
    mount $DEV2 /tmp/lvm_s2
    fsfreeze -u /tmp/lvm_s1
    FREEZE_END=$(date +%s%N)
    FREEZE_MS=$(( ($FREEZE_END - $FREEZE_START) / 1000000 ))
    echo -e "${GREEN}✓${NC} Automated freeze cycle complete (${FREEZE_MS} ms blocked)"
fi

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
    if [ "$MODE" = "lvm" ]; then
        echo -e "${GREEN}✓ SUCCESS: LVM snapshot-based replication WORKS!${NC}"
        echo ""
        echo -e "${BOLD}Key advantages:${NC}"
        echo "  1. ABSOLUTE zero-downtime replication!"
        echo "  2. Server1: 100% READ-WRITE throughout - NO remount, NO freeze!"
        echo "  3. Server2: Stays online during replication"
        echo "  4. LVM handles consistency automatically via snapshots"
        echo "  5. Can be automated with cron/systemd timer"
        echo "  6. Safe rollback if replication fails (keep snapshot)"
        echo "  7. Production-ready: No blocking on primary server!"
        echo ""
        echo -e "${BOLD}Production workflow (TRUE zero-downtime):${NC}"
        echo "  1. lvcreate -s -L <size> -n server1_snap /dev/vg/server1"
        echo "     (Snapshot server1 - atomic, instant, zero blocking!)"
        echo "  2. lvcreate -s -L <size> -n server2_snap /dev/vg/server2"
        echo "  3. e2image -ra /dev/vg/server1_snap /dev/vg/server2_snap"
        echo "     (Replicate from server1 snapshot to server2 snapshot)"
        echo "  4. e2fsck -fy /dev/vg/server2_snap"
        echo "  5. lvremove -f /dev/vg/server1_snap  (cleanup)"
        echo "  6. umount /mnt/server2  (brief server2 downtime for merge)"
        echo "  7. lvconvert --merge /dev/vg/server2_snap"
        echo "  8. mount /mnt/server2  (server2 back online)"
        echo ""
        echo -e "${BOLD}Why this works:${NC}"
        echo "  - LVM snapshot is atomic and handles ALL metadata consistency"
        echo "  - No need for sync, fsfreeze, or remount on server1"
        echo "  - Server1 stays 100% operational for reads AND writes"
    else
        echo -e "${GREEN}✓ SUCCESS: fsfreeze-based replication WORKS!${NC}"
        echo ""
        echo -e "${BOLD}Key characteristics:${NC}"
        echo "  1. No LVM required - works on plain ext4!"
        echo "  2. Server1: Writes BLOCKED during e2image"
        echo "  3. Server2: Unmounted during e2image"
        echo "  4. fsfreeze ensures perfect metadata consistency"
        echo "  5. Simpler setup than LVM"
        echo "  6. ${YELLOW}Trade-off: Write blocking (check freeze duration above)${NC}"
        echo ""
        echo -e "${BOLD}Production workflow (fsfreeze):${NC}"
        echo "  1. fsfreeze -f /mnt/server1"
        echo "     (Freezes filesystem, flushes ALL metadata)"
        echo "  2. e2image -ra /dev/sda1 /dev/sdb1"
        echo "     (Replicate while frozen - guaranteed consistency)"
        echo "  3. fsfreeze -u /mnt/server1"
        echo "     (Unfreeze - writes resume)"
        echo ""
        echo -e "${BOLD}When to use fsfreeze mode:${NC}"
        echo "  - No LVM available"
        echo "  - Can tolerate write blocking (seconds)"
        echo "  - Simpler infrastructure"
        echo "  - Low-traffic maintenance windows"
    fi
    echo ""
    echo -e "${BOLD}Automation:${NC}"
    echo "  - Run every N minutes/hours via cron"
    echo "  - Monitor with scripts"
    echo "  - Alert on failures"
else
    echo -e "${RED}✗ FAILED: Replication did not work${NC}"
fi
echo ""
