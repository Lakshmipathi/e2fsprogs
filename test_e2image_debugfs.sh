#!/bin/bash
#
# test_e2image_debugfs.sh - Test e2image incremental without mounting
#
# Uses debugfs to manipulate filesystems without needing mount
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

E2FSPROGS_DIR=/home/user/e2fsprogs

echo -e "${BOLD}${CYAN}====================================================================="
echo "E2IMAGE INCREMENTAL TEST USING DEBUGFS"
echo "====================================================================${NC}"
echo ""

cd /tmp
rm -f server1.img server2.img file1.txt file2.txt

echo -e "${BOLD}${YELLOW}PHASE 1: INITIAL SETUP${NC}"
echo ""

echo -e "${CYAN}[1/4] Creating server1.img${NC}"
dd if=/dev/zero of=server1.img bs=1M count=100 2>/dev/null
$E2FSPROGS_DIR/misc/mke2fs -t ext4 -F server1.img >/dev/null 2>&1
echo -e "${GREEN}✓${NC} Created"

echo -e "${CYAN}[2/4] Creating file1.txt using debugfs${NC}"
echo "First file - initial sync" > /tmp/file1.txt
$E2FSPROGS_DIR/debugfs/debugfs -w server1.img -R "write /tmp/file1.txt file1.txt" 2>/dev/null
echo -e "${GREEN}✓${NC} file1.txt written to server1"

echo -e "${CYAN}[3/4] Initial replication to server2${NC}"
$E2FSPROGS_DIR/misc/e2image -ra server1.img server2.img 2>&1 | tail -2
$E2FSPROGS_DIR/e2fsck/e2fsck -fy server2.img >/dev/null 2>&1 || [ $? -le 2 ]
echo -e "${GREEN}✓${NC} Replicated"

echo -e "${CYAN}[4/4] Changing server2 UUID${NC}"
$E2FSPROGS_DIR/misc/tune2fs -U random server2.img >/dev/null 2>&1
echo -e "${GREEN}✓${NC} UUID changed"

echo -e "${CYAN}Verifying file1.txt on server2 using debugfs${NC}"
if $E2FSPROGS_DIR/debugfs/debugfs server2.img -R "ls -l" 2>/dev/null | grep -q "file1.txt"; then
    echo -e "${GREEN}✓${NC} file1.txt exists on server2"
else
    echo -e "${RED}✗${NC} Initial replication failed"
    exit 1
fi
echo ""

echo -e "${BOLD}${YELLOW}PHASE 2: INCREMENTAL REPLICATION${NC}"
echo ""

echo -e "${CYAN}[1/4] Creating file2.txt on server1${NC}"
echo "Second file - created after initial sync" > /tmp/file2.txt
$E2FSPROGS_DIR/debugfs/debugfs -w server1.img -R "write /tmp/file2.txt file2.txt" 2>/dev/null
echo -e "${GREEN}✓${NC} file2.txt written to server1"

echo -e "${CYAN}[2/4] Verifying file2.txt on server1${NC}"
echo "  Files on server1:"
$E2FSPROGS_DIR/debugfs/debugfs server1.img -R "ls -l" 2>/dev/null | grep "\.txt" | sed 's/^/    /'
if $E2FSPROGS_DIR/debugfs/debugfs server1.img -R "ls -l" 2>/dev/null | grep -q "file2.txt"; then
    echo -e "  ${GREEN}✓${NC} file2.txt EXISTS on server1"
else
    echo -e "  ${RED}✗${NC} file2.txt MISSING on server1"
    exit 1
fi

echo -e "${CYAN}[3/4] Running incremental e2image${NC}"
$E2FSPROGS_DIR/misc/e2image -ra server1.img server2.img 2>&1 | tail -2
$E2FSPROGS_DIR/e2fsck/e2fsck -fy server2.img >/dev/null 2>&1 || [ $? -le 2 ]
echo -e "${GREEN}✓${NC} Replication complete"

echo -e "${CYAN}[4/4] Checking files on server2${NC}"
echo "  Files on server2:"
$E2FSPROGS_DIR/debugfs/debugfs server2.img -R "ls -l" 2>/dev/null | grep "\.txt" | sed 's/^/    /' || echo "    (no .txt files)"

SUCCESS=false
if $E2FSPROGS_DIR/debugfs/debugfs server2.img -R "ls -l" 2>/dev/null | grep -q "file2.txt"; then
    echo -e "  ${GREEN}✓✓✓ SUCCESS! file2.txt appears on server2${NC}"
    # Extract and verify content
    $E2FSPROGS_DIR/debugfs/debugfs server2.img -R "dump file2.txt /tmp/file2_check.txt" 2>/dev/null
    CONTENT=$(cat /tmp/file2_check.txt)
    echo "  Content: '$CONTENT'"
    if [ "$CONTENT" = "Second file - created after initial sync" ]; then
        echo -e "  ${GREEN}✓✓✓ Content MATCHES!${NC}"
        SUCCESS=true
    fi
else
    echo -e "  ${RED}✗${NC} file2.txt NOT found on server2"
fi

echo ""
echo -e "${BOLD}${CYAN}====================================================================="
echo "RESULTS"
echo "====================================================================${NC}"
echo ""

if [ "$SUCCESS" = "true" ]; then
    echo -e "${GREEN}✓ SUCCESS: e2image CAN do incremental replication!${NC}"
    echo ""
    echo "The LVM snapshot issue must be LVM-specific."
else
    echo -e "${RED}✗ FAILED: e2image CANNOT do incremental replication${NC}"
    echo ""
    echo "This means e2image is not designed for this use case."
    echo "It creates full copies, not incremental syncs."
fi
echo ""

rm -f /tmp/file1.txt /tmp/file2.txt /tmp/file2_check.txt
