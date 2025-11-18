#!/bin/bash
#
# diagnose_instant_checkpoint.sh - Understand why checkpoint happens instantly
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
echo "DIAGNOSING INSTANT CHECKPOINT ISSUE"
echo "====================================================================${NC}"
echo ""

cleanup() {
    umount /tmp/diag_mnt 2>/dev/null || true
    losetup -d /dev/loop30 2>/dev/null || true
    rm -rf /tmp/diagnose_checkpoint
}
cleanup

mkdir -p /tmp/diagnose_checkpoint
cd /tmp/diagnose_checkpoint

echo -e "${YELLOW}TEST 1: Default mount options${NC}"
echo "Creating filesystem..."
dd if=/dev/zero of=test1.img bs=1M count=50 2>/dev/null
$E2FSPROGS_DIR/misc/mke2fs -t ext4 -F test1.img >/dev/null 2>&1

losetup /dev/loop30 test1.img
mkdir -p /tmp/diag_mnt
mount /dev/loop30 /tmp/diag_mnt

echo "Creating file..."
echo "test" > /tmp/diag_mnt/testfile.txt
sync  # Force commit

echo "Checking journal state..."
SEQ=$($E2FSPROGS_DIR/misc/dumpe2fs test1.img 2>/dev/null | grep "Journal sequence:" | awk '{print $3}')
START=$($E2FSPROGS_DIR/misc/dumpe2fs test1.img 2>/dev/null | grep "Journal start:" | awk '{print $3}')
echo "  Sequence: $SEQ, Start: $START"

umount /tmp/diag_mnt
losetup -d /dev/loop30
echo ""

echo -e "${YELLOW}TEST 2: data=journal mode${NC}"
echo "Creating filesystem..."
dd if=/dev/zero of=test2.img bs=1M count=50 2>/dev/null
$E2FSPROGS_DIR/misc/mke2fs -t ext4 -F test2.img >/dev/null 2>&1

losetup /dev/loop30 test2.img
mount -o data=journal /dev/loop30 /tmp/diag_mnt

echo "Creating file..."
echo "test" > /tmp/diag_mnt/testfile.txt
# DON'T sync - check immediately

echo "Checking journal state (no sync)..."
SEQ=$($E2FSPROGS_DIR/misc/dumpe2fs test2.img 2>/dev/null | grep "Journal sequence:" | awk '{print $3}')
START=$($E2FSPROGS_DIR/misc/dumpe2fs test2.img 2>/dev/null | grep "Journal start:" | awk '{print $3}')
echo "  Sequence: $SEQ, Start: $START"

umount /tmp/diag_mnt
losetup -d /dev/loop30
echo ""

echo -e "${YELLOW}TEST 3: data=journal + commit=9999${NC}"
echo "Creating filesystem..."
dd if=/dev/zero of=test3.img bs=1M count=50 2>/dev/null
$E2FSPROGS_DIR/misc/mke2fs -t ext4 -F test3.img >/dev/null 2>&1

losetup /dev/loop30 test3.img
mount -o data=journal,commit=9999 /dev/loop30 /tmp/diag_mnt

echo "Creating file..."
echo "test" > /tmp/diag_mnt/testfile.txt
# DON'T sync

echo "Checking journal state (no sync)..."
SEQ=$($E2FSPROGS_DIR/misc/dumpe2fs test3.img 2>/dev/null | grep "Journal sequence:" | awk '{print $3}')
START=$($E2FSPROGS_DIR/misc/dumpe2fs test3.img 2>/dev/null | grep "Journal start:" | awk '{print $3}')
echo "  Sequence: $SEQ, Start: $START"

umount /tmp/diag_mnt
losetup -d /dev/loop30
echo ""

echo -e "${YELLOW}TEST 4: Check journal size${NC}"
echo "Creating filesystem with larger journal..."
dd if=/dev/zero of=test4.img bs=1M count=100 2>/dev/null
$E2FSPROGS_DIR/misc/mke2fs -t ext4 -J size=64 -F test4.img >/dev/null 2>&1

losetup /dev/loop30 test4.img
mount -o data=journal,commit=9999,barrier=0 /dev/loop30 /tmp/diag_mnt

JSIZE=$($E2FSPROGS_DIR/misc/dumpe2fs test4.img 2>/dev/null | grep "Journal size:" | awk '{print $3}')
echo "  Journal size: ${JSIZE}"

echo "Creating file..."
echo "test content" > /tmp/diag_mnt/testfile.txt

echo "Checking journal immediately..."
SEQ=$($E2FSPROGS_DIR/misc/dumpe2fs test4.img 2>/dev/null | grep "Journal sequence:" | awk '{print $3}')
START=$($E2FSPROGS_DIR/misc/dumpe2fs test4.img 2>/dev/null | grep "Journal start:" | awk '{print $3}')
echo "  Sequence: $SEQ, Start: $START"

umount /tmp/diag_mnt
losetup -d /dev/loop30
echo ""

echo -e "${YELLOW}TEST 5: Check /proc/mounts for actual options${NC}"
dd if=/dev/zero of=test5.img bs=1M count=50 2>/dev/null
$E2FSPROGS_DIR/misc/mke2fs -t ext4 -F test5.img >/dev/null 2>&1

losetup /dev/loop30 test5.img
mount -o data=journal,commit=9999,barrier=0 /dev/loop30 /tmp/diag_mnt

echo "Requested options: data=journal,commit=9999,barrier=0"
echo "Actual mount options:"
grep "/tmp/diag_mnt" /proc/mounts | sed 's/^/  /'

umount /tmp/diag_mnt
losetup -d /dev/loop30
echo ""

cleanup

echo -e "${BOLD}${CYAN}ANALYSIS:${NC}"
echo ""
echo "If all tests show Start: 0"
echo "  → Journal checkpoints instantly regardless of options"
echo "  → ext4 might not support delaying checkpoints in data=journal mode"
echo "  → Journal-based replication may not be feasible"
echo ""
echo "Possible reasons:"
echo "  1. data=journal mode aggressively checkpoints for performance"
echo "  2. commit= only controls commit, not checkpoint timing"
echo "  3. Small journal size forces immediate checkpoint"
echo "  4. Kernel version doesn't support delayed checkpoints"
echo ""
echo "Next steps:"
echo "  - Check kernel journal code (/proc/fs/jbd2/)"
echo "  - Try different approach (inotify + block-level sync)"
echo "  - Consider using dm-era or dm-log-writes for replication"
echo ""
