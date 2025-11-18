#!/bin/bash
#
# test_direct_capture_single_file.sh - Test direct capture for single file
#
# This tests the direct block reading approach to see if it avoids the
# checkpoint timing issue. Focuses on just ONE file (file1.txt) as requested.
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BOLD}${CYAN}===================================================================="
echo "SINGLE FILE REPLICATION TEST - Direct Capture Method"
echo "====================================================================${NC}"
echo ""
echo -e "${YELLOW}Goal: Replicate file1.txt from server1 to server2${NC}"
echo -e "${YELLOW}Method: Direct journal block reads (bypass debugfs)${NC}"
echo ""

# Cleanup
cleanup() {
    umount /tmp/test_mnt_s1 2>/dev/null || true
    umount /tmp/test_mnt_s2 2>/dev/null || true
    losetup -d /dev/loop30 2>/dev/null || true
    losetup -d /dev/loop31 2>/dev/null || true
    rm -rf /tmp/test_direct_single_file
}
cleanup

mkdir -p /tmp/test_direct_single_file
cd /tmp/test_direct_single_file

echo -e "${BOLD}${YELLOW}PHASE 1: SETUP${NC}"
echo ""

echo -e "${CYAN}[1/3] Creating server1 filesystem${NC}"
dd if=/dev/zero of=server1.img bs=1M count=100 2>/dev/null
../misc/mke2fs -t ext4 -F server1.img >/dev/null 2>&1
echo -e "${GREEN}✓${NC} server1.img created (100MB)"

echo -e "${CYAN}[2/3] Creating identical server2 filesystem${NC}"
cp server1.img server2.img
echo -e "${GREEN}✓${NC} server2.img created (identical copy)"

echo -e "${CYAN}[3/3] Verifying checksums${NC}"
HASH1=$(md5sum server1.img | awk '{print $1}')
HASH2=$(md5sum server2.img | awk '{print $1}')
if [ "$HASH1" = "$HASH2" ]; then
    echo -e "${GREEN}✓${NC} Checksums match"
else
    echo -e "${RED}✗${NC} ERROR: Checksums don't match"
    exit 1
fi
echo ""

echo -e "${BOLD}${YELLOW}PHASE 2: CREATE FILE ON SERVER1${NC}"
echo ""

echo -e "${CYAN}[1/3] Mounting server1 with data=journal,commit=9999${NC}"
losetup /dev/loop30 server1.img
mkdir -p /tmp/test_mnt_s1
mount -o data=journal,barrier=0,commit=9999 /dev/loop30 /tmp/test_mnt_s1
echo -e "${GREEN}✓${NC} Mounted at /tmp/test_mnt_s1"

echo -e "${CYAN}[2/3] Creating file1.txt${NC}"
echo "Hello from server1 - test content for file1.txt" > /tmp/test_mnt_s1/file1.txt
CREATE_TIME=$(date +%s)
echo -e "${GREEN}✓${NC} file1.txt created at timestamp: $CREATE_TIME"
ls -la /tmp/test_mnt_s1/file1.txt

echo -e "${CYAN}[3/3] Checking journal state immediately${NC}"
SEQ_BEFORE=$(../misc/dumpe2fs server1.img 2>/dev/null | grep "^Journal sequence:" | awk '{print $3}')
START_BEFORE=$(../misc/dumpe2fs server1.img 2>/dev/null | grep "^Journal start:" | awk '{print $3}')
echo "  Sequence: $SEQ_BEFORE"
echo "  Start: $START_BEFORE"
if [ "$START_BEFORE" = "0" ]; then
    echo -e "  ${RED}⚠ Journal is already checkpointed!${NC}"
else
    echo -e "  ${GREEN}✓ Journal has transactions${NC}"
fi
echo ""

echo -e "${BOLD}${YELLOW}PHASE 3: CAPTURE WITH DIRECT METHOD${NC}"
echo ""

echo -e "${CYAN}[1/2] Using direct capture (dd with iflag=direct)${NC}"
../journal_capture_direct.sh server1.img capture_direct 2>&1 | grep -E "✓|⚠|ERROR|Sequence|Start|Captured" | sed 's/^/  /'

echo -e "${CYAN}[2/2] Verifying capture contains data${NC}"
if [ -f capture_direct/journal_blocks.raw ]; then
    CAPTURE_SIZE=$(stat -f "%z" capture_direct/journal_blocks.raw 2>/dev/null || stat -c "%s" capture_direct/journal_blocks.raw 2>/dev/null)
    echo -e "  ${GREEN}✓${NC} Captured journal: $CAPTURE_SIZE bytes"

    # Check if capture contains any non-zero data
    if [ "$CAPTURE_SIZE" -gt 0 ]; then
        # Use xxd or hexdump to check for non-zero bytes
        if command -v xxd > /dev/null; then
            NON_ZERO=$(xxd capture_direct/journal_blocks.raw | head -20 | grep -v "0000 0000 0000 0000" | wc -l || echo "0")
            echo "  Non-zero lines in first 20: $NON_ZERO"
            if [ "$NON_ZERO" -gt 0 ]; then
                echo -e "  ${GREEN}✓${NC} Journal contains data"
            else
                echo -e "  ${YELLOW}⚠${NC} Journal appears to be all zeros"
            fi
        fi
    else
        echo -e "  ${RED}✗${NC} Capture file is empty"
    fi
else
    echo -e "  ${RED}✗${NC} Capture file not found"
fi
echo ""

echo -e "${BOLD}${YELLOW}PHASE 4: CHECK TIMING${NC}"
echo ""

echo -e "${CYAN}[1/1] Wait 2 seconds and check if journal persists${NC}"
sleep 2
SEQ_AFTER=$(../misc/dumpe2fs server1.img 2>/dev/null | grep "^Journal sequence:" | awk '{print $3}')
START_AFTER=$(../misc/dumpe2fs server1.img 2>/dev/null | grep "^Journal start:" | awk '{print $3}')
echo "  Sequence: $SEQ_BEFORE → $SEQ_AFTER"
echo "  Start: $START_BEFORE → $START_AFTER"

if [ "$START_AFTER" = "0" ]; then
    echo -e "  ${RED}⚠ Journal checkpointed after 2 seconds${NC}"
else
    echo -e "  ${GREEN}✓ Journal still has transactions after 2 seconds${NC}"
fi
echo ""

echo -e "${BOLD}${YELLOW}PHASE 5: VERIFY FILE NOT ON SERVER2${NC}"
echo ""

echo -e "${CYAN}[1/1] Mounting server2 to verify it's empty${NC}"
losetup /dev/loop31 server2.img
mkdir -p /tmp/test_mnt_s2
mount /dev/loop31 /tmp/test_mnt_s2

if [ -f /tmp/test_mnt_s2/file1.txt ]; then
    echo -e "  ${RED}✗${NC} file1.txt already exists on server2 (unexpected)"
else
    echo -e "  ${GREEN}✓${NC} file1.txt does NOT exist on server2 (expected)"
fi

umount /tmp/test_mnt_s2
losetup -d /dev/loop31
echo ""

echo -e "${BOLD}${YELLOW}PHASE 6: INJECT AND VERIFY${NC}"
echo ""

echo -e "${CYAN}[1/3] Unmounting server1${NC}"
umount /tmp/test_mnt_s1
losetup -d /dev/loop30
echo -e "${GREEN}✓${NC} Unmounted"

echo -e "${CYAN}[2/3] Injecting journal into server2${NC}"
# Check if we captured valid journal data
if [ -f capture_direct/capture_metadata.txt ]; then
    source capture_direct/capture_metadata.txt

    if [ "$JOURNAL_START" != "0" ]; then
        echo "  Using traditional injection (captured active journal)"
        ../journal_replicate_inject.sh server2.img capture_direct 2>&1 | grep -E "✓|⚠|ERROR" | sed 's/^/  /'
    else
        echo -e "  ${YELLOW}⚠ Skipping injection - journal was empty${NC}"
    fi
else
    echo -e "  ${YELLOW}⚠ No metadata file found${NC}"
fi

echo -e "${CYAN}[3/3] Running e2fsck to replay journal${NC}"
../e2fsck/e2fsck -fy server2.img 2>&1 | head -5 | sed 's/^/  /'
echo ""

echo -e "${BOLD}${YELLOW}PHASE 7: VERIFY REPLICATION${NC}"
echo ""

echo -e "${CYAN}[1/2] Mounting server2 and checking for file1.txt${NC}"
losetup /dev/loop31 server2.img
mount /dev/loop31 /tmp/test_mnt_s2

if [ -f /tmp/test_mnt_s2/file1.txt ]; then
    CONTENT=$(cat /tmp/test_mnt_s2/file1.txt)
    echo -e "  ${GREEN}✓✓✓ SUCCESS! file1.txt exists on server2${NC}"
    echo "  Content: '$CONTENT'"
else
    echo -e "  ${RED}✗ FAILED - file1.txt NOT found on server2${NC}"
    echo "  Files on server2:"
    ls -la /tmp/test_mnt_s2 | sed 's/^/    /'
fi

echo -e "${CYAN}[2/2] Cleanup${NC}"
cleanup
echo -e "${GREEN}✓${NC} Done"
echo ""

echo -e "${BOLD}${CYAN}===================================================================="
echo "ANALYSIS"
echo "====================================================================${NC}"
echo ""
echo "This test shows whether direct block reading avoids checkpoint issues."
echo ""
echo "Key questions answered:"
echo "  1. Does direct dd capture avoid triggering checkpoint?"
echo "  2. How long does journal persist with commit=9999?"
echo "  3. Can we successfully replicate file1.txt?"
echo ""
echo "If replication SUCCEEDED:"
echo "  → Direct capture method works!"
echo "  → Can use this for continuous replication"
echo ""
echo "If replication FAILED:"
echo "  → Journal checkpoints too fast even with direct reads"
echo "  → Need alternative approach (kernel module, different architecture)"
echo ""
