#!/bin/bash
#
# Enhanced Journal Explorer with Parsing and Block Tracing
# Integrates journal parsing and file block tracing into the learning experience
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Configuration
IMG_FILE="/tmp/journal_test.img"
MOUNT_POINT="/tmp/journal_mnt"
OUTPUT_DIR="/tmp/journal_output_$$"
IMG_SIZE_MB=100
JOURNAL_SIZE=8

mkdir -p "$OUTPUT_DIR"

# Cleanup
cleanup() {
    echo -e "\n${YELLOW}Cleaning up...${NC}"
    umount "$MOUNT_POINT" 2>/dev/null || true
    losetup -d "$LOOP_DEV" 2>/dev/null || true
    rm -rf "$MOUNT_POINT"
    rm -f "$IMG_FILE"
    echo -e "${CYAN}Analysis files preserved in: $OUTPUT_DIR${NC}"
}

trap cleanup EXIT

print_header() {
    clear
    echo -e "${BOLD}${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║    ENHANCED JOURNAL EXPLORER WITH BLOCK TRACING           ║${NC}"
    echo -e "${BOLD}${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo
}

wait_for_user() {
    echo -e "\n${YELLOW}Press ENTER to continue...${NC}"
    read
}

section_header() {
    echo -e "\n${BOLD}${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${MAGENTA}  $1${NC}"
    echo -e "${BOLD}${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

step() {
    echo -e "${BOLD}${GREEN}[STEP $CURRENT_STEP]${NC} ${BOLD}$1${NC}"
    CURRENT_STEP=$((CURRENT_STEP + 1))
}

info_box() {
    echo -e "${BLUE}╔═══ INFO ═══════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC} $1"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════╝${NC}"
}

CURRENT_STEP=1

print_header
echo -e "${BOLD}This enhanced tutorial will:${NC}"
echo -e "  ${GREEN}✓${NC} Parse and explain journal superblock fields"
echo -e "  ${GREEN}✓${NC} Trace file blocks through journal transactions"
echo -e "  ${GREEN}✓${NC} Map journal contents to filesystem operations"
echo -e "  ${GREEN}✓${NC} Save all analysis to files for review"
echo
echo -e "${CYAN}Output directory: $OUTPUT_DIR${NC}"
echo

wait_for_user

# ============================================================================
# SETUP
# ============================================================================

section_header "PHASE 1: FILESYSTEM SETUP"

step "Creating test filesystem"
dd if=/dev/zero of="$IMG_FILE" bs=1M count=$IMG_SIZE_MB status=progress
./misc/mke2fs -t ext4 -J size=$JOURNAL_SIZE -F "$IMG_FILE" > /dev/null 2>&1
echo -e "${GREEN}✓ Filesystem created${NC}"
wait_for_user

# ============================================================================
# INITIAL JOURNAL ANALYSIS
# ============================================================================

section_header "PHASE 2: INITIAL JOURNAL SUPERBLOCK ANALYSIS"

step "Parsing journal superblock (before any operations)"
info_box "Each field will be explained with its purpose"
echo

SUPERBLOCK_INITIAL="$OUTPUT_DIR/01_superblock_initial.txt"
./misc/dumpe2fs "$IMG_FILE" 2>/dev/null | grep -A 30 "^Journal" | tee "$SUPERBLOCK_INITIAL"

echo
echo -e "${CYAN}Key fields explained:${NC}"
echo

# Parse Journal sequence
if grep -q "Journal sequence" "$SUPERBLOCK_INITIAL"; then
    seq=$(grep "Journal sequence" "$SUPERBLOCK_INITIAL" | awk '{print $NF}')
    echo -e "${BOLD}s_sequence:${NC} $seq"
    echo -e "  ${BLUE}→ Transaction ID counter - increments with each commit${NC}"
    echo
fi

# Parse Journal start
if grep -q "Journal start:" "$SUPERBLOCK_INITIAL"; then
    start=$(grep "Journal start:" "$SUPERBLOCK_INITIAL" | awk '{print $NF}')
    echo -e "${BOLD}s_start:${NC} $start"
    echo -e "  ${BLUE}→ Where recovery begins (0 = no pending transactions)${NC}"
    echo
fi

# Parse Total journal blocks
if grep -q "Total journal blocks" "$SUPERBLOCK_INITIAL"; then
    maxlen=$(grep "Total journal blocks" "$SUPERBLOCK_INITIAL" | awk '{print $NF}')
    echo -e "${BOLD}s_maxlen:${NC} $maxlen blocks"
    echo -e "  ${BLUE}→ Total journal size (circular buffer)${NC}"
    echo
fi

# Parse Total journal size
if grep -q "Total journal size" "$SUPERBLOCK_INITIAL"; then
    size=$(grep "Total journal size" "$SUPERBLOCK_INITIAL" | awk '{print $NF}')
    echo -e "${BOLD}Journal Size:${NC} $size"
    echo -e "  ${BLUE}→ Human-readable total size${NC}"
    echo
fi

echo -e "${GREEN}✓${NC} Saved to: $SUPERBLOCK_INITIAL"
wait_for_user

# ============================================================================
# CREATE FILE AND TRACE
# ============================================================================

section_header "PHASE 3: CREATE FILE AND TRACE BLOCKS"

step "Setting up loop device and mounting"
LOOP_DEV=$(losetup -f)
losetup "$LOOP_DEV" "$IMG_FILE"
mkdir -p "$MOUNT_POINT"
# Mount with data=journal mode - journals ALL data, not just metadata
# This creates much more journal activity that's easier to capture
mount -o data=journal,barrier=0,commit=9999 "$LOOP_DEV" "$MOUNT_POINT"
echo -e "${GREEN}✓ Mounted at: $MOUNT_POINT${NC}"
echo -e "${BLUE}  (data=journal mode - all data goes through journal)${NC}"
wait_for_user

step "Creating file: abc.txt"
info_box "We'll create multiple files to generate persistent journal activity"
echo
DATE_OUTPUT=$(date)
# Create the main file
echo "$DATE_OUTPUT" > "$MOUNT_POINT/abc.txt"
echo -e "${GREEN}✓ abc.txt created${NC}"

# Create additional files to fill the journal
for i in {1..5}; do
    echo "Test file $i with some data: $(date +%s%N)" > "$MOUNT_POINT/test$i.txt"
done
echo -e "${GREEN}✓ Created 5 additional test files${NC}"

cat "$MOUNT_POINT/abc.txt"
echo

# Sync to push transactions TO journal (but barrier=0 prevents immediate checkpoint)
echo -e "${CYAN}Flushing transactions to journal (not checkpointing)...${NC}"
sync
echo -e "${GREEN}✓ Transactions in journal${NC}"
wait_for_user

step "Capturing journal state"

# Capture journal while filesystem is still mounted
# In data=journal mode with multiple files, journal should have content
JOURNAL_DUMP="$OUTPUT_DIR/04_full_journal_dump.txt"
echo -e "${CYAN}Capturing journal state (data=journal mode with active transactions)...${NC}"
./debugfs/debugfs -R "logdump -a" "$IMG_FILE" 2>/dev/null > "$JOURNAL_DUMP"
echo -e "${GREEN}✓${NC} Journal captured to: $JOURNAL_DUMP"

echo -e "${CYAN}Preview of journal dump:${NC}"
head -30 "$JOURNAL_DUMP"
echo
wait_for_user

# Now unmount cleanly
echo -e "${CYAN}Unmounting filesystem...${NC}"
umount "$MOUNT_POINT"
losetup -d "$LOOP_DEV"
echo -e "${GREEN}✓ Unmounted${NC}"

FILE_INFO="$OUTPUT_DIR/02_abc_file_info.txt"

# Get inode using debugfs ncheck with -R flag - search for file in root
INODE=$(./debugfs/debugfs -R "ncheck /abc.txt" "$IMG_FILE" 2>/dev/null | grep -v "Inode" | awk '{print $1}' | head -1)

# If not found with /, try without
if [ -z "$INODE" ] || [ "$INODE" = "debugfs:" ]; then
    INODE=$(./debugfs/debugfs -R "ls -l" "$IMG_FILE" 2>/dev/null | grep "abc.txt" | awk '{print $1}')
fi

echo -e "${CYAN}File information:${NC}"
if [ -n "$INODE" ] && [ "$INODE" != "debugfs:" ]; then
    ./debugfs/debugfs -R "stat <$INODE>" "$IMG_FILE" 2>/dev/null | tee "$FILE_INFO"
    echo
    echo -e "${GREEN}✓${NC} Inode number: ${BOLD}$INODE${NC}"
    echo -e "${GREEN}✓${NC} Saved to: $FILE_INFO"
    echo

    # Extract blocks - handle both BLOCKS: and EXTENTS: formats
    BLOCKS=$(./debugfs/debugfs -R "stat <$INODE>" "$IMG_FILE" 2>/dev/null | grep -E "(BLOCKS:|EXTENTS:)" -A 10 | grep -oE '\([0-9]+\):?[0-9]+' | grep -oE '[0-9]+$' | head -10)

    echo -e "${YELLOW}Data blocks used by abc.txt:${NC}"
    if [ -n "$BLOCKS" ]; then
        for block in $BLOCKS; do
            echo -e "  ${BOLD}Block $block${NC}"
        done
    else
        echo -e "  ${BLUE}(file uses inline data - no separate blocks allocated)${NC}"
    fi
else
    echo -e "${YELLOW}Could not find inode for abc.txt${NC}" | tee "$FILE_INFO"
    BLOCKS=""
fi
echo

wait_for_user

# ============================================================================
# JOURNAL ANALYSIS AFTER FILE CREATION
# ============================================================================

section_header "PHASE 4: JOURNAL ANALYSIS AFTER FILE CREATION"

step "Dumping journal superblock (after file creation)"
SUPERBLOCK_AFTER="$OUTPUT_DIR/03_superblock_after_create.txt"
./misc/dumpe2fs "$IMG_FILE" 2>/dev/null | grep -A 30 "^Journal" | tee "$SUPERBLOCK_AFTER"
echo
echo -e "${GREEN}✓${NC} Saved to: $SUPERBLOCK_AFTER"
echo

step "Comparing journal state"
echo -e "${CYAN}Comparing initial vs. after file creation:${NC}"
echo

OLD_SEQ=$(grep "Journal sequence" "$SUPERBLOCK_INITIAL" 2>/dev/null | awk '{print $NF}')
NEW_SEQ=$(grep "Journal sequence" "$SUPERBLOCK_AFTER" 2>/dev/null | awk '{print $NF}')

echo -e "  ${BOLD}s_sequence${NC}"
echo -e "    Before: ${OLD_SEQ:-N/A}"
echo -e "    After:  ${NEW_SEQ:-N/A}"
if [ -n "$OLD_SEQ" ] && [ -n "$NEW_SEQ" ] && [ "$OLD_SEQ" != "$NEW_SEQ" ]; then
    echo -e "    ${GREEN}→ Transaction committed! Sequence increased.${NC}"
elif [ -n "$OLD_SEQ" ] && [ -n "$NEW_SEQ" ]; then
    echo -e "    ${YELLOW}→ Sequence unchanged (transaction may be in cache)${NC}"
fi
echo

OLD_START=$(grep "Journal start:" "$SUPERBLOCK_INITIAL" 2>/dev/null | awk '{print $NF}')
NEW_START=$(grep "Journal start:" "$SUPERBLOCK_AFTER" 2>/dev/null | awk '{print $NF}')

echo -e "  ${BOLD}s_start${NC}"
echo -e "    Before: ${OLD_START:-N/A}"
echo -e "    After:  ${NEW_START:-N/A}"
if [ -n "$OLD_START" ] && [ -n "$NEW_START" ] && [ "$OLD_START" != "$NEW_START" ]; then
    echo -e "    ${CYAN}→ Recovery position changed${NC}"
fi
echo

wait_for_user

step "Reviewing captured journal dump"
echo -e "${CYAN}Journal dump preview (first 30 lines):${NC}"
head -30 "$JOURNAL_DUMP"
echo
echo -e "${GREEN}✓${NC} Full journal saved to: $JOURNAL_DUMP"
wait_for_user

# ============================================================================
# BLOCK TRACING
# ============================================================================

section_header "PHASE 5: TRACING abc.txt BLOCKS IN JOURNAL"

step "Searching journal for file blocks"
info_box "Looking for blocks $BLOCKS in journal transactions"
echo

BLOCK_TRACE="$OUTPUT_DIR/05_block_trace.txt"
echo "BLOCK TRACE RESULTS:" > "$BLOCK_TRACE"
echo >> "$BLOCK_TRACE"
echo -e "${BOLD}${YELLOW}BLOCK TRACE RESULTS:${NC}\n"

found_any=0
current_trans=""

if [ -n "$BLOCKS" ]; then
    while IFS= read -r line; do
        if echo "$line" | grep -q "Found expected sequence"; then
            current_trans=$(echo "$line" | awk '{print $4}' | tr -d ',')
        fi

        for block in $BLOCKS; do
            if echo "$line" | grep -qE "\\b$block\\b"; then
                if [ "$found_any" = "0" ]; then
                    echo "✓ Found file blocks in journal!" >> "$BLOCK_TRACE"
                    echo >> "$BLOCK_TRACE"
                    echo -e "${GREEN}✓ Found file blocks in journal!${NC}\n"
                    found_any=1
                fi
                echo "Transaction $current_trans:" >> "$BLOCK_TRACE"
                echo "  Block $block: $line" >> "$BLOCK_TRACE"
                echo >> "$BLOCK_TRACE"

                echo -e "${MAGENTA}Transaction $current_trans:${NC}"
                echo -e "  ${CYAN}Block $block:${NC} $line"
                echo
            fi
        done
    done < "$JOURNAL_DUMP"
fi

if [ "$found_any" = "0" ]; then
    {
        echo "No direct block references found in journal."
        echo "Possible reasons:"
        echo "  • File uses inline data (stored in inode)"
        echo "  • Transaction already checkpointed"
        echo "  • Journal wrapped around"
    } >> "$BLOCK_TRACE"

    echo -e "${YELLOW}No direct block references found in journal.${NC}"
    echo -e "${BLUE}Possible reasons:${NC}"
    echo -e "  • File uses inline data (stored in inode)${NC}"
    echo -e "  • Transaction already checkpointed${NC}"
    echo -e "  • Journal wrapped around${NC}"
fi

echo
echo -e "${GREEN}✓${NC} Block trace saved to: $BLOCK_TRACE"
wait_for_user

# ============================================================================
# TRANSACTION BREAKDOWN
# ============================================================================

section_header "PHASE 6: TRANSACTION BREAKDOWN"

step "Analyzing transaction structure"
TRANSACTION_ANALYSIS="$OUTPUT_DIR/06_transaction_analysis.txt"

# Write header to file without ANSI codes
echo "TRANSACTION ANALYSIS:" > "$TRANSACTION_ANALYSIS"
echo >> "$TRANSACTION_ANALYSIS"

# Display colored header on terminal
echo -e "${BOLD}${YELLOW}TRANSACTION ANALYSIS:${NC}\n"

# Count block types (capture to variable to avoid newline issues)
# Note: grep -c returns 0 and exits with status 1 when no matches, so we need to handle that
# Match actual logdump format: "type 1 (descriptor block)"
desc_count=$(grep -c "type 1 (descriptor block)" "$JOURNAL_DUMP" 2>/dev/null)
desc_count=${desc_count:-0}
commit_count=$(grep -c "type 2 (commit block)" "$JOURNAL_DUMP" 2>/dev/null)
commit_count=${commit_count:-0}
revoke_count=$(grep -c "type 5 (revoke block)" "$JOURNAL_DUMP" 2>/dev/null)
revoke_count=${revoke_count:-0}

# Write to both terminal and file (no tee to avoid ANSI codes in file)
{
    echo "Block Type Counts:"
    echo "  Descriptor blocks: $desc_count"
    echo "    → Define what filesystem blocks are being modified"
    echo "  Commit blocks: $commit_count"
    echo "    → Mark transactions as complete (atomic commit point)"
    echo "  Revoke blocks: $revoke_count"
    echo "    → List blocks that should NOT be replayed (deletions)"
    echo
} >> "$TRANSACTION_ANALYSIS"

# Display with colors on terminal
echo -e "${CYAN}Block Type Counts:${NC}"
echo -e "  Descriptor blocks: ${BOLD}$desc_count${NC}"
echo -e "    ${BLUE}→ Define what filesystem blocks are being modified${NC}"
echo -e "  Commit blocks: ${BOLD}$commit_count${NC}"
echo -e "    ${BLUE}→ Mark transactions as complete (atomic commit point)${NC}"
echo -e "  Revoke blocks: ${BOLD}$revoke_count${NC}"
echo -e "    ${BLUE}→ List blocks that should NOT be replayed (deletions)${NC}"
echo

# Transaction sequences - write to file without colors
{
    echo "Transaction Sequences:"
    grep "Found expected sequence" "$JOURNAL_DUMP" 2>/dev/null | while read -r line; do
        seq=$(echo "$line" | awk '{print $4}' | tr -d ',')
        echo "  Transaction ID: $seq"
    done | head -5
    echo
} >> "$TRANSACTION_ANALYSIS"

# Display with colors
echo -e "${CYAN}Transaction Sequences:${NC}"
grep "Found expected sequence" "$JOURNAL_DUMP" 2>/dev/null | while read -r line; do
    seq=$(echo "$line" | awk '{print $4}' | tr -d ',')
    echo -e "  Transaction ID: ${BOLD}$seq${NC}"
done | head -5
echo

if [ "$desc_count" -gt 0 ]; then
    {
        echo "Filesystem Blocks Modified in Transactions:"
        echo
        grep "FS block.*logged at" "$JOURNAL_DUMP" 2>/dev/null | head -20
        echo
        echo "What these blocks contain:"
        echo "  Block 1 = Superblock (filesystem metadata)"
        echo "  Block 2 = Group descriptors (block group info)"
        echo "  Block 260-261 = Block bitmaps (which blocks are free/used)"
        echo "  Block 272 = Inode bitmap (which inodes are free/used)"
        echo "  Block 285/288/289 = Inode tables & directory blocks"
        echo "  Block 8705+, 16385+ = Data blocks (your file contents)"
        echo
    } >> "$TRANSACTION_ANALYSIS"

    echo -e "${CYAN}Filesystem Blocks Modified in Transactions:${NC}"
    echo
    grep "FS block.*logged at" "$JOURNAL_DUMP" 2>/dev/null | head -20
    echo
    echo -e "${BLUE}What these blocks contain:${NC}"
    echo -e "  Block 1 = ${BOLD}Superblock${NC} (filesystem metadata)"
    echo -e "  Block 2 = ${BOLD}Group descriptors${NC} (block group info)"
    echo -e "  Block 260-261 = ${BOLD}Block bitmaps${NC} (which blocks are free/used)"
    echo -e "  Block 272 = ${BOLD}Inode bitmap${NC} (which inodes are free/used)"
    echo -e "  Block 285/288/289 = ${BOLD}Inode tables & directories${NC}"
    echo -e "  Block 8705+, 16385+ = ${BOLD}Data blocks${NC} (your file contents)"
    echo
fi

echo -e "${GREEN}✓${NC} Analysis saved to: $TRANSACTION_ANALYSIS"
wait_for_user

# ============================================================================
# SUMMARY
# ============================================================================

section_header "ANALYSIS SUMMARY"

echo -e "${BOLD}${GREEN}All analysis files generated:${NC}\n"

ls -lh "$OUTPUT_DIR" | tail -n +2 | while read -r line; do
    filename=$(echo "$line" | awk '{print $NF}')
    size=$(echo "$line" | awk '{print $5}')
    echo -e "  ${CYAN}$filename${NC} ($size)"
done

echo
echo -e "${BOLD}${YELLOW}Quick Reference:${NC}"
echo -e "  1. Initial journal state:      $SUPERBLOCK_INITIAL"
echo -e "  2. File inode info:            $FILE_INFO"
echo -e "  3. Journal after creation:     $SUPERBLOCK_AFTER"
echo -e "  4. Full journal dump:          $JOURNAL_DUMP"
echo -e "  5. Block trace:                $BLOCK_TRACE"
echo -e "  6. Transaction analysis:       $TRANSACTION_ANALYSIS"
echo

echo -e "${BOLD}${CYAN}Understanding the Results:${NC}"
echo
echo -e "${YELLOW}Journal Superblock Fields:${NC}"
echo -e "  • ${BOLD}s_sequence${NC} = Transaction counter (increases with each commit)"
echo -e "  • ${BOLD}s_start${NC} = Recovery starting point (block offset in journal)"
echo -e "  • ${BOLD}s_maxlen${NC} = Total journal size in blocks"
echo -e "  • ${BOLD}s_errno${NC} = Error code (0 = clean)"
echo
echo -e "${YELLOW}File Block Tracing:${NC}"
if [ -n "$INODE" ] && [ "$INODE" != "debugfs:" ]; then
    echo -e "  • File inode: $INODE"
    echo -e "  • Data blocks: ${BLOCKS:-inline data}"
    echo -e "  • Journal references: $([ "$found_any" = "1" ] && echo "Yes" || echo "No (checkpointed or inline data)")"
else
    echo -e "  • File inode: Not found"
fi
echo
echo -e "${YELLOW}Transaction Structure:${NC}"
echo -e "  Each transaction = Descriptor + Metadata blocks + Commit"
echo -e "  • Descriptor: Lists which blocks are being written"
echo -e "  • Metadata: Actual data being journaled"
echo -e "  • Commit: Atomicity guarantee (transaction is valid)"
echo

echo -e "${BOLD}${GREEN}Files are preserved in: ${CYAN}$OUTPUT_DIR${NC}"
echo -e "${YELLOW}Review them to understand the journal layout!${NC}"
echo

wait_for_user
