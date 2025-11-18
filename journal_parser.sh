#!/bin/bash
#
# Journal Parser and File Block Tracer
# Parse journal superblock and trace file blocks through journal
#
# Usage: ./journal_parser.sh <filesystem_image> [filename]

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

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <filesystem_image> [filename]"
    echo
    echo "Examples:"
    echo "  $0 /tmp/test.img              # Parse journal superblock"
    echo "  $0 /tmp/test.img abc.txt      # Parse journal + trace file blocks"
    exit 1
fi

IMG="$1"
FILENAME="${2:-}"
OUTPUT_DIR="/tmp/journal_analysis_$$"

mkdir -p "$OUTPUT_DIR"

cleanup() {
    rm -rf "$OUTPUT_DIR"
}
trap cleanup EXIT

print_header() {
    echo -e "${BOLD}${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║          JOURNAL PARSER AND BLOCK TRACER                  ║${NC}"
    echo -e "${BOLD}${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo
}

section() {
    echo -e "\n${BOLD}${MAGENTA}━━━ $1 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

# ============================================================================
# PART 1: PARSE JOURNAL SUPERBLOCK
# ============================================================================

parse_journal_superblock() {
    section "JOURNAL SUPERBLOCK ANALYSIS"

    local superblock_file="$OUTPUT_DIR/journal_superblock.txt"
    local parsed_file="$OUTPUT_DIR/journal_superblock_parsed.txt"

    echo -e "${CYAN}Dumping journal superblock...${NC}"
    ./debugfs/debugfs -R "logdump -s" "$IMG" 2>/dev/null > "$superblock_file"

    echo -e "${GREEN}✓${NC} Saved to: $superblock_file"
    echo

    # Parse and explain each field
    echo -e "${BOLD}${YELLOW}PARSED JOURNAL SUPERBLOCK WITH EXPLANATIONS:${NC}\n" | tee "$parsed_file"

    # Extract key fields and explain them
    while IFS= read -r line; do
        case "$line" in
            *"Journal starts at block"*)
                block=$(echo "$line" | awk '{print $NF}')
                echo -e "${CYAN}Journal Start Block:${NC} $block" | tee -a "$parsed_file"
                echo -e "  ${BLUE}→ Physical block where journal begins on disk${NC}" | tee -a "$parsed_file"
                echo -e "  ${BLUE}→ Usually block 1 for inline journals${NC}" | tee -a "$parsed_file"
                echo | tee -a "$parsed_file"
                ;;
            *"Journal sequence"*)
                seq=$(echo "$line" | awk '{print $NF}')
                echo -e "${CYAN}Journal Sequence:${NC} $seq" | tee -a "$parsed_file"
                echo -e "  ${BLUE}→ Transaction ID of first expected transaction${NC}" | tee -a "$parsed_file"
                echo -e "  ${BLUE}→ Increments with each committed transaction${NC}" | tee -a "$parsed_file"
                echo | tee -a "$parsed_file"
                ;;
            *"Journal start"*)
                start=$(echo "$line" | awk '{print $NF}')
                echo -e "${CYAN}Journal Start (s_start):${NC} $start" | tee -a "$parsed_file"
                echo -e "  ${BLUE}→ Block offset where recovery should begin${NC}" | tee -a "$parsed_file"
                echo -e "  ${BLUE}→ Points to oldest uncommitted transaction${NC}" | tee -a "$parsed_file"
                echo -e "  ${BLUE}→ Updated after successful checkpoint${NC}" | tee -a "$parsed_file"
                echo | tee -a "$parsed_file"
                ;;
            *"Journal number of users"*)
                users=$(echo "$line" | awk '{print $NF}')
                echo -e "${CYAN}Number of Users (s_nr_users):${NC} $users" | tee -a "$parsed_file"
                echo -e "  ${BLUE}→ Number of filesystems sharing this journal${NC}" | tee -a "$parsed_file"
                echo -e "  ${BLUE}→ Usually 1 for inline journals${NC}" | tee -a "$parsed_file"
                echo | tee -a "$parsed_file"
                ;;
            *"Journal maxlen"*)
                maxlen=$(echo "$line" | awk '{print $NF}')
                echo -e "${CYAN}Max Length (s_maxlen):${NC} $maxlen blocks" | tee -a "$parsed_file"
                echo -e "  ${BLUE}→ Total size of journal in blocks${NC}" | tee -a "$parsed_file"
                echo -e "  ${BLUE}→ Journal wraps around when full (circular buffer)${NC}" | tee -a "$parsed_file"
                echo | tee -a "$parsed_file"
                ;;
            *"Journal block size"*)
                blocksize=$(echo "$line" | awk '{print $NF}')
                echo -e "${CYAN}Block Size (s_blocksize):${NC} $blocksize bytes" | tee -a "$parsed_file"
                echo -e "  ${BLUE}→ Size of each journal block${NC}" | tee -a "$parsed_file"
                echo -e "  ${BLUE}→ Usually matches filesystem block size${NC}" | tee -a "$parsed_file"
                echo | tee -a "$parsed_file"
                ;;
            *"Journal first block"*)
                first=$(echo "$line" | awk '{print $NF}')
                echo -e "${CYAN}First Block (s_first):${NC} $first" | tee -a "$parsed_file"
                echo -e "  ${BLUE}→ First block of log information${NC}" | tee -a "$parsed_file"
                echo -e "  ${BLUE}→ Usually 1 (block 0 is superblock)${NC}" | tee -a "$parsed_file"
                echo | tee -a "$parsed_file"
                ;;
            *"Journal errno"*)
                errno=$(echo "$line" | awk '{print $NF}')
                echo -e "${CYAN}Error Number (s_errno):${NC} $errno" | tee -a "$parsed_file"
                if [ "$errno" = "0" ]; then
                    echo -e "  ${GREEN}→ No errors detected${NC}" | tee -a "$parsed_file"
                else
                    echo -e "  ${RED}→ Error code: $errno${NC}" | tee -a "$parsed_file"
                fi
                echo | tee -a "$parsed_file"
                ;;
            *"Journal feature_compat"*)
                compat=$(echo "$line" | awk '{print $NF}')
                echo -e "${CYAN}Compatible Features (s_feature_compat):${NC} $compat" | tee -a "$parsed_file"
                echo -e "  ${BLUE}→ Features that are backward compatible${NC}" | tee -a "$parsed_file"
                [ $((compat & 0x1)) -ne 0 ] && echo -e "  ${GREEN}  ✓ CHECKSUM (0x1)${NC}" | tee -a "$parsed_file"
                echo | tee -a "$parsed_file"
                ;;
            *"Journal feature_incompat"*)
                incompat=$(echo "$line" | awk '{print $NF}')
                echo -e "${CYAN}Incompatible Features (s_feature_incompat):${NC} $incompat" | tee -a "$parsed_file"
                echo -e "  ${BLUE}→ Features that break backward compatibility${NC}" | tee -a "$parsed_file"
                [ $((incompat & 0x1)) -ne 0 ] && echo -e "  ${GREEN}  ✓ REVOKE (0x1) - Block revocation support${NC}" | tee -a "$parsed_file"
                [ $((incompat & 0x2)) -ne 0 ] && echo -e "  ${GREEN}  ✓ 64BIT (0x2) - 64-bit block numbers${NC}" | tee -a "$parsed_file"
                [ $((incompat & 0x4)) -ne 0 ] && echo -e "  ${GREEN}  ✓ ASYNC_COMMIT (0x4) - Async commit${NC}" | tee -a "$parsed_file"
                [ $((incompat & 0x8)) -ne 0 ] && echo -e "  ${GREEN}  ✓ CSUM_V2 (0x8) - Checksum v2${NC}" | tee -a "$parsed_file"
                [ $((incompat & 0x10)) -ne 0 ] && echo -e "  ${GREEN}  ✓ CSUM_V3 (0x10) - Checksum v3${NC}" | tee -a "$parsed_file"
                [ $((incompat & 0x20)) -ne 0 ] && echo -e "  ${GREEN}  ✓ FAST_COMMIT (0x20) - Fast commit${NC}" | tee -a "$parsed_file"
                echo | tee -a "$parsed_file"
                ;;
            *"Journal feature_ro_compat"*)
                rocompat=$(echo "$line" | awk '{print $NF}')
                echo -e "${CYAN}RO-Compatible Features (s_feature_ro_compat):${NC} $rocompat" | tee -a "$parsed_file"
                echo -e "  ${BLUE}→ Features that allow read-only mounting${NC}" | tee -a "$parsed_file"
                echo | tee -a "$parsed_file"
                ;;
            *"Journal uuid"*)
                uuid=$(echo "$line" | sed 's/.*Journal uuid: *//')
                echo -e "${CYAN}Journal UUID (s_uuid):${NC} $uuid" | tee -a "$parsed_file"
                echo -e "  ${BLUE}→ Unique identifier for this journal${NC}" | tee -a "$parsed_file"
                echo -e "  ${BLUE}→ Ensures journal matches filesystem${NC}" | tee -a "$parsed_file"
                echo | tee -a "$parsed_file"
                ;;
            *"Journal max transaction length"*)
                max_trans=$(echo "$line" | awk '{print $NF}')
                echo -e "${CYAN}Max Transaction Length (s_max_transaction):${NC} $max_trans blocks" | tee -a "$parsed_file"
                echo -e "  ${BLUE}→ Maximum blocks allowed in one transaction${NC}" | tee -a "$parsed_file"
                echo -e "  ${BLUE}→ Limits transaction size to prevent journal overflow${NC}" | tee -a "$parsed_file"
                echo | tee -a "$parsed_file"
                ;;
            *"Journal max transaction data length"*)
                max_data=$(echo "$line" | awk '{print $NF}')
                echo -e "${CYAN}Max Transaction Data Length (s_max_trans_data):${NC} $max_data blocks" | tee -a "$parsed_file"
                echo -e "  ${BLUE}→ Maximum data blocks in one transaction${NC}" | tee -a "$parsed_file"
                echo -e "  ${BLUE}→ Excludes descriptor and commit blocks${NC}" | tee -a "$parsed_file"
                echo | tee -a "$parsed_file"
                ;;
        esac
    done < "$superblock_file"

    echo -e "${GREEN}✓${NC} Parsed output saved to: $parsed_file"
    echo
    echo -e "${YELLOW}View parsed output:${NC} cat $parsed_file"
    echo
}

# ============================================================================
# PART 2: TRACE FILE BLOCKS THROUGH JOURNAL
# ============================================================================

trace_file_blocks() {
    local filename="$1"

    section "FILE BLOCK TRACER: $filename"

    local journal_dump="$OUTPUT_DIR/journal_full.txt"
    local file_info="$OUTPUT_DIR/file_info.txt"
    local block_map="$OUTPUT_DIR/block_map.txt"

    # Step 1: Get file inode and blocks
    echo -e "${CYAN}Step 1: Getting file information...${NC}"

    # Get inode number
    local inode=$(echo "ncheck $filename" | ./debugfs/debugfs "$IMG" 2>/dev/null | grep -v "Inode" | awk '{print $1}')

    if [ -z "$inode" ]; then
        echo -e "${RED}✗ File '$filename' not found in filesystem${NC}"
        return 1
    fi

    echo -e "${GREEN}✓${NC} File: $filename"
    echo -e "${GREEN}✓${NC} Inode: $inode"
    echo

    # Get inode details
    echo "stat <$inode>" | ./debugfs/debugfs "$IMG" 2>/dev/null > "$file_info"

    # Extract block numbers
    echo -e "${CYAN}Step 2: Extracting file blocks...${NC}"
    local blocks=$(grep "BLOCKS:" "$file_info" -A 10 | grep -oE '\([0-9]+\)' | tr -d '()' | head -20)

    echo -e "${YELLOW}File blocks used by $filename:${NC}" | tee "$block_map"
    if [ -n "$blocks" ]; then
        for block in $blocks; do
            echo -e "  Block ${BOLD}$block${NC}" | tee -a "$block_map"
        done
    else
        echo -e "  ${BLUE}(inline data or no blocks allocated yet)${NC}" | tee -a "$block_map"
    fi
    echo

    # Step 3: Dump full journal
    echo -e "${CYAN}Step 3: Dumping journal contents...${NC}"
    ./debugfs/debugfs -R "logdump -a" "$IMG" 2>/dev/null > "$journal_dump"
    echo -e "${GREEN}✓${NC} Journal dumped to: $journal_dump"
    echo

    # Step 4: Find file blocks in journal
    echo -e "${CYAN}Step 4: Searching for file blocks in journal...${NC}"
    echo -e "\n${BOLD}${YELLOW}JOURNAL TRANSACTIONS REFERENCING FILE BLOCKS:${NC}\n" | tee -a "$block_map"

    local found=0
    local current_trans=""
    local in_descriptor=0

    while IFS= read -r line; do
        # Track transaction sequence
        if echo "$line" | grep -q "Found expected sequence"; then
            current_trans=$(echo "$line" | awk '{print $4}' | tr -d ',')
            in_descriptor=0
        fi

        # Check for descriptor blocks
        if echo "$line" | grep -q "Descriptor block"; then
            in_descriptor=1
        fi

        # Check for commit blocks
        if echo "$line" | grep -q "Commit block"; then
            in_descriptor=0
        fi

        # Search for our file's blocks in descriptor tags
        if [ "$in_descriptor" = "1" ]; then
            for block in $blocks; do
                if echo "$line" | grep -qE "\\b$block\\b"; then
                    if [ "$found" = "0" ]; then
                        echo -e "${GREEN}Found references to file blocks!${NC}\n" | tee -a "$block_map"
                    fi
                    found=1
                    echo -e "${MAGENTA}Transaction $current_trans:${NC}" | tee -a "$block_map"
                    echo -e "  ${CYAN}→${NC} $line" | tee -a "$block_map"
                    echo | tee -a "$block_map"
                fi
            done
        fi
    done < "$journal_dump"

    if [ "$found" = "0" ]; then
        echo -e "${YELLOW}No journal transactions found referencing these blocks.${NC}" | tee -a "$block_map"
        echo -e "${BLUE}This could mean:${NC}" | tee -a "$block_map"
        echo -e "  ${BLUE}• File was created before journal existed${NC}" | tee -a "$block_map"
        echo -e "  ${BLUE}• Transactions have been checkpointed (written to filesystem)${NC}" | tee -a "$block_map"
        echo -e "  ${BLUE}• Journal has wrapped around and overwritten old entries${NC}" | tee -a "$block_map"
    else
        echo -e "${GREEN}✓ Found file block references in journal!${NC}" | tee -a "$block_map"
    fi
    echo

    # Step 5: Show inode details
    echo -e "${CYAN}Step 5: File inode details:${NC}"
    echo
    cat "$file_info"
    echo

    echo -e "${GREEN}✓${NC} Block map saved to: $block_map"
    echo
    echo -e "${YELLOW}Summary:${NC}"
    echo -e "  Inode: $inode"
    echo -e "  Blocks: $(echo $blocks | wc -w)"
    echo -e "  Journal references: $([ "$found" = "1" ] && echo "Yes" || echo "No")"
    echo
}

# ============================================================================
# PART 3: ADVANCED ANALYSIS
# ============================================================================

advanced_analysis() {
    section "ADVANCED JOURNAL ANALYSIS"

    local journal_dump="$OUTPUT_DIR/journal_full.txt"
    local stats_file="$OUTPUT_DIR/journal_stats.txt"

    if [ ! -f "$journal_dump" ]; then
        ./debugfs/debugfs -R "logdump -a" "$IMG" 2>/dev/null > "$journal_dump"
    fi

    echo -e "${BOLD}${YELLOW}JOURNAL STATISTICS:${NC}\n" | tee "$stats_file"

    # Count transaction types
    local desc_count=$(grep -c "Descriptor block" "$journal_dump" || echo "0")
    local commit_count=$(grep -c "Commit block" "$journal_dump" || echo "0")
    local revoke_count=$(grep -c "Revoke block" "$journal_dump" || echo "0")

    echo -e "${CYAN}Transaction Block Counts:${NC}" | tee -a "$stats_file"
    echo -e "  Descriptor blocks: $desc_count" | tee -a "$stats_file"
    echo -e "  Commit blocks: $commit_count" | tee -a "$stats_file"
    echo -e "  Revoke blocks: $revoke_count" | tee -a "$stats_file"
    echo | tee -a "$stats_file"

    # Extract transaction sequences
    echo -e "${CYAN}Transaction Sequences:${NC}" | tee -a "$stats_file"
    grep "Found expected sequence" "$journal_dump" | head -10 | while read -r line; do
        echo -e "  $line" | tee -a "$stats_file"
    done
    echo | tee -a "$stats_file"

    # Check for revoke blocks
    if [ "$revoke_count" -gt 0 ]; then
        echo -e "${YELLOW}Revoke Blocks Found:${NC}" | tee -a "$stats_file"
        grep -A 5 "Revoke block" "$journal_dump" | head -20 | tee -a "$stats_file"
        echo | tee -a "$stats_file"
    fi

    echo -e "${GREEN}✓${NC} Statistics saved to: $stats_file"
    echo
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

print_header

if [ ! -f "$IMG" ]; then
    echo -e "${RED}Error: File '$IMG' not found${NC}"
    exit 1
fi

echo -e "${BOLD}Analyzing: ${CYAN}$IMG${NC}\n"

# Always parse journal superblock
parse_journal_superblock

# If filename provided, trace its blocks
if [ -n "$FILENAME" ]; then
    trace_file_blocks "$FILENAME"
fi

# Show advanced analysis
advanced_analysis

# Summary
section "ANALYSIS COMPLETE"

echo -e "${GREEN}✓${NC} All analysis files saved in: ${CYAN}$OUTPUT_DIR${NC}"
echo
echo -e "${YELLOW}Generated files:${NC}"
ls -lh "$OUTPUT_DIR" | tail -n +2 | while read -r line; do
    echo "  $line"
done
echo
echo -e "${BOLD}${CYAN}Keep these files? They will be deleted on exit.${NC}"
echo -e "${YELLOW}To preserve, copy from: $OUTPUT_DIR${NC}"
echo

read -p "Press ENTER to exit and cleanup..."
