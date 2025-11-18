#!/bin/bash
#
# Journal Block Inspector
# Detailed inspection of individual journal blocks
#
# Usage: ./journal_block_inspector.sh <filesystem_image>

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
    echo "Usage: $0 <filesystem_image>"
    exit 1
fi

IMG="$1"

if [ ! -f "$IMG" ]; then
    echo "Error: File $IMG not found"
    exit 1
fi

# Magic number
JBD2_MAGIC=0xc03b3998

print_header() {
    echo -e "${BOLD}${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║         JOURNAL BLOCK INSPECTOR - DETAILED ANALYSIS       ║${NC}"
    echo -e "${BOLD}${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo
}

section() {
    echo -e "\n${BOLD}${MAGENTA}━━━ $1 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

# Decode block type
decode_block_type() {
    case $1 in
        1) echo "DESCRIPTOR_BLOCK (Transaction descriptor)" ;;
        2) echo "COMMIT_BLOCK (Transaction commit record)" ;;
        3) echo "SUPERBLOCK_V1 (Journal superblock v1)" ;;
        4) echo "SUPERBLOCK_V2 (Journal superblock v2)" ;;
        5) echo "REVOKE_BLOCK (Block revocation records)" ;;
        6) echo "FC_BLOCK (Fast commit block)" ;;
        *) echo "UNKNOWN ($1)" ;;
    esac
}

# Decode feature flags
decode_compat_features() {
    local flags=$1
    echo -e "${CYAN}Compatible features:${NC}"
    [ $((flags & 0x1)) -ne 0 ] && echo "  - CHECKSUM (Journal checksumming)"
}

decode_incompat_features() {
    local flags=$1
    echo -e "${CYAN}Incompatible features:${NC}"
    [ $((flags & 0x1)) -ne 0 ] && echo "  - REVOKE (Revoke block support)"
    [ $((flags & 0x2)) -ne 0 ] && echo "  - 64BIT (64-bit block numbers)"
    [ $((flags & 0x4)) -ne 0 ] && echo "  - ASYNC_COMMIT (Async commit)"
    [ $((flags & 0x8)) -ne 0 ] && echo "  - CSUM_V2 (Checksum v2)"
    [ $((flags & 0x10)) -ne 0 ] && echo "  - CSUM_V3 (Checksum v3)"
    [ $((flags & 0x20)) -ne 0 ] && echo "  - FAST_COMMIT (Fast commit support)"
}

# Get journal inode number
get_journal_inode() {
    local img="$1"
    # Journal is typically inode 8
    echo 8
}

# Display hex dump with annotations
annotated_hexdump() {
    local file=$1
    local offset=$2
    local length=$3
    local title=$4

    echo -e "${YELLOW}$title${NC}"
    echo -e "${CYAN}Offset: $offset, Length: $length bytes${NC}"
    dd if="$file" bs=1 skip=$offset count=$length 2>/dev/null | hexdump -C | head -20
}

print_header

# ============================================================================
# JOURNAL SUPERBLOCK ANALYSIS
# ============================================================================

section "JOURNAL SUPERBLOCK ANALYSIS"

echo -e "${BOLD}Extracting journal superblock...${NC}\n"

# Get journal info using dumpe2fs
JOURNAL_INFO=$(./misc/dumpe2fs "$IMG" 2>/dev/null | grep -A 30 "^Journal")

echo -e "${CYAN}Journal Information from dumpe2fs:${NC}"
echo "$JOURNAL_INFO"
echo

# Get journal inode
JOURNAL_INODE=$(get_journal_inode "$IMG")

echo -e "${CYAN}Journal inode: ${BOLD}$JOURNAL_INODE${NC}"
echo

# Use debugfs to show journal inode details
echo -e "${CYAN}Journal inode details:${NC}"
echo "stat <$JOURNAL_INODE>" | ./debugfs/debugfs "$IMG" 2>/dev/null

echo
echo -e "${CYAN}Journal superblock (using logdump):${NC}"
./debugfs/debugfs -R "logdump -s" "$IMG" 2>/dev/null

# ============================================================================
# TRANSACTION DUMP
# ============================================================================

section "TRANSACTION ANALYSIS"

echo -e "${BOLD}Dumping first 3 transactions in detail...${NC}\n"

./debugfs/debugfs -R "logdump -n 3" "$IMG" 2>/dev/null

echo
read -p "Press ENTER to see full journal dump..."
echo

section "FULL JOURNAL DUMP"

./debugfs/debugfs -R "logdump -a" "$IMG" 2>/dev/null

# ============================================================================
# BLOCK TAG ANALYSIS
# ============================================================================

section "UNDERSTANDING BLOCK TAGS"

cat << 'EOF'
Block tags appear in descriptor blocks and define which filesystem
blocks are being written in the transaction.

journal_block_tag_t (12 bytes for v2, 16 bytes for v3):

Offset  Size  Field           Description
------  ----  -----           -----------
0       4     t_blocknr       Filesystem block number (lower 32 bits)
4       2     t_checksum      CRC32C checksum of metadata block
6       2     t_flags         Flags (see below)
8       4     t_blocknr_high  Upper 32 bits of block number (64-bit)

Flags (t_flags):
  0x001  JBD2_FLAG_ESCAPE     Block starts with journal magic (escaped)
  0x002  JBD2_FLAG_SAME_UUID  No UUID needed (same as journal)
  0x004  JBD2_FLAG_DELETED    Block was deleted (revoked)
  0x008  JBD2_FLAG_LAST_TAG   Last tag in descriptor block

For v3 (CSUM_V3):
  - Full 32-bit checksum instead of 16-bit
  - Different tag layout

Descriptor Block Layout:
  +0: journal_header_t (12 bytes)
      - h_magic (0xc03b3998)
      - h_blocktype (1)
      - h_sequence (transaction ID)
  +12: journal_block_tag_t #1
  +24: journal_block_tag_t #2
  ...
  +N: journal_block_tag_t #last (FLAG_LAST_TAG set)

After descriptor: metadata blocks (one per tag)
EOF

echo
read -p "Press ENTER to continue..."

# ============================================================================
# REVOKE BLOCK ANALYSIS
# ============================================================================

section "REVOKE BLOCK STRUCTURE"

cat << 'EOF'
Revoke blocks list blocks that should NOT be replayed during recovery.

journal_revoke_header_t:

Offset  Size  Field           Description
------  ----  -----           -----------
0       4     h_magic         Journal magic (0xc03b3998)
4       4     h_blocktype     Block type (5 = REVOKE)
8       4     h_sequence      Transaction ID
12      4     r_count         Bytes used in this block

16+     8*N   Block list      Array of 64-bit block numbers to revoke

Example:
  If r_count = 32, then:
    - Header uses 16 bytes
    - Remaining 16 bytes = 2 revoked blocks (8 bytes each)

Maximum revoked blocks per 4KB journal block:
  (4096 - 16) / 8 = 510 blocks

During recovery:
  1. Read all revoke blocks
  2. Build hash table of revoked blocks
  3. When replaying descriptor blocks:
     - Check each block tag against revoke table
     - Skip replaying if found in table
EOF

echo
echo -e "${CYAN}Searching for revoke blocks in journal:${NC}"
echo
./debugfs/debugfs -R "logdump -a" "$IMG" 2>/dev/null | grep -i -A 10 "revoke"

echo
read -p "Press ENTER to continue..."

# ============================================================================
# COMMIT BLOCK ANALYSIS
# ============================================================================

section "COMMIT BLOCK STRUCTURE"

cat << 'EOF'
Commit blocks mark the end of a transaction. Only transactions with
valid commit blocks are replayed during recovery.

struct commit_header:

Offset  Size  Field             Description
------  ----  -----             -----------
0       4     h_magic           Journal magic (0xc03b3998)
4       4     h_blocktype       Block type (2 = COMMIT)
8       4     h_sequence        Transaction ID (matches descriptor)
12      1     h_chksum_type     Checksum algorithm (1 = CRC32C)
13      1     h_chksum_size     Checksum size in 32-bit words
14      2     (padding)
16      32    h_chksum[8]       Transaction checksum (CRC32C)
48      8     h_commit_sec      Commit timestamp (seconds since epoch)
56      4     h_commit_nsec     Commit timestamp (nanoseconds)

Checksum calculation:
  - CRC32C of entire transaction
  - Includes: descriptor blocks + metadata blocks + revoke blocks
  - Does NOT include commit block itself
  - Stored in h_chksum array

Transaction is valid if:
  1. Commit block has correct magic
  2. Commit block sequence matches descriptor sequence
  3. Checksum is valid (if checksums enabled)

Atomic commit guarantee:
  - Commit block written last
  - If commit block not present/valid → transaction not replayed
  - Ensures all-or-nothing transaction semantics
EOF

echo
echo -e "${CYAN}Example commit blocks from journal:${NC}"
echo
./debugfs/debugfs -R "logdump -a" "$IMG" 2>/dev/null | grep -i -A 5 "commit block"

echo
read -p "Press ENTER to continue..."

# ============================================================================
# RECOVERY ALGORITHM
# ============================================================================

section "RECOVERY ALGORITHM DETAILS"

cat << 'EOF'
Recovery algorithm (from e2fsck/recovery.c):

int jbd2_journal_recover(journal_t *journal)
{
    1. Read journal superblock
       - Get s_start (first uncommitted transaction)
       - Get s_sequence (expected transaction ID)
       - Get s_maxlen (journal size)

    2. SCAN PHASE - do_one_pass(PASS_SCAN)
       - Scan from s_start forward
       - For each block:
         a. Check magic number
         b. Verify sequence number
         c. Process descriptor/commit/revoke blocks
       - Build list of valid transactions
       - Find highest committed transaction

    3. REVOKE PHASE - do_one_pass(PASS_REVOKE)
       - Process all revoke blocks
       - Build revoke hash table
       - Map: (block_number, transaction_id) → revoked

    4. REPLAY PHASE - do_one_pass(PASS_REPLAY)
       - For each valid transaction:
         a. Read descriptor block
         b. For each block tag:
            - Extract filesystem block number
            - Check if revoked
            - If not revoked:
              * Read metadata block from journal
              * Write to filesystem
         c. Verify commit block
       - Update free space maps
       - Clear journal blocks

    5. CLEANUP
       - Update journal superblock
       - Set s_start = s_sequence (no pending transactions)
       - Clear s_errno
       - Write updated journal superblock
       - Sync filesystem

    return 0; /* Success */
}

Key data structure:

struct recovery_info {
    tid_t  start_transaction;    /* First transaction ID */
    tid_t  end_transaction;      /* Last transaction ID */
    int    nr_replays;           /* Blocks replayed */
    int    nr_revokes;           /* Blocks revoked */
    int    nr_revoke_hits;       /* Revoked blocks skipped */
};

Scan loop (simplified):

while (offset < journal_end) {
    read_block(journal, offset, &header);

    if (header.h_magic != JBD2_MAGIC)
        break; /* End of valid journal */

    if (header.h_sequence != expected_seq)
        break; /* Sequence break */

    switch (header.h_blocktype) {
    case DESCRIPTOR:
        process_descriptor_block();
        break;
    case COMMIT:
        mark_transaction_committed();
        expected_seq++;
        break;
    case REVOKE:
        add_revoke_records();
        break;
    }

    offset++;
}
EOF

echo
read -p "Press ENTER to continue..."

# ============================================================================
# INTERACTIVE MENU
# ============================================================================

section "INTERACTIVE EXPLORATION"

while true; do
    echo
    echo -e "${BOLD}${CYAN}Choose an option:${NC}"
    echo "  1. Show journal superblock"
    echo "  2. Dump all transactions"
    echo "  3. Dump specific number of transactions"
    echo "  4. Search for revoke blocks"
    echo "  5. Show commit blocks only"
    echo "  6. Show journal statistics"
    echo "  7. Launch debugfs (manual exploration)"
    echo "  8. Show data structure reference"
    echo "  9. Exit"
    echo
    read -p "Enter choice [1-9]: " choice

    case $choice in
        1)
            echo
            ./debugfs/debugfs -R "logdump -s" "$IMG" 2>/dev/null
            ;;
        2)
            echo
            ./debugfs/debugfs -R "logdump -a" "$IMG" 2>/dev/null | less
            ;;
        3)
            read -p "Enter number of transactions: " num
            echo
            ./debugfs/debugfs -R "logdump -n $num" "$IMG" 2>/dev/null
            ;;
        4)
            echo
            ./debugfs/debugfs -R "logdump -a" "$IMG" 2>/dev/null | grep -i -B 2 -A 10 "revoke"
            ;;
        5)
            echo
            ./debugfs/debugfs -R "logdump -a" "$IMG" 2>/dev/null | grep -i -A 5 "commit block"
            ;;
        6)
            echo
            ./misc/dumpe2fs "$IMG" 2>/dev/null | grep -A 30 "^Journal"
            echo
            LOGDUMP=$(./debugfs/debugfs -R "logdump -a" "$IMG" 2>/dev/null)
            echo -e "${CYAN}Transaction count:${NC}"
            echo "$LOGDUMP" | grep -c "Found expected sequence" || echo "0"
            echo -e "${CYAN}Descriptor blocks:${NC}"
            echo "$LOGDUMP" | grep -c "Descriptor block" || echo "0"
            echo -e "${CYAN}Commit blocks:${NC}"
            echo "$LOGDUMP" | grep -c "Commit block" || echo "0"
            echo -e "${CYAN}Revoke blocks:${NC}"
            echo "$LOGDUMP" | grep -c "Revoke block" || echo "0"
            ;;
        7)
            echo
            echo -e "${YELLOW}Launching debugfs (type 'quit' to exit)${NC}"
            echo
            ./debugfs/debugfs "$IMG"
            ;;
        8)
            cat << 'EOF'

═══════════════════════════════════════════════════════════════
                  DATA STRUCTURE QUICK REFERENCE
═══════════════════════════════════════════════════════════════

JOURNAL HEADER (12 bytes) - Start of every journal block
  +0  __be32  h_magic       0xc03b3998
  +4  __be32  h_blocktype   1=DESC, 2=COMMIT, 3/4=SUPER, 5=REVOKE
  +8  __be32  h_sequence    Transaction ID

JOURNAL SUPERBLOCK (1024 bytes)
  +0   journal_header_t
  +12  __be32  s_blocksize      Journal block size
  +16  __be32  s_maxlen         Total blocks in journal
  +20  __be32  s_first          First block of log
  +24  __be32  s_sequence       First commit ID expected
  +28  __be32  s_start          Blocknr of start of log
  +32  __s32   s_errno          Error value
  +36  __be32  s_feature_compat
  +40  __be32  s_feature_incompat
  +44  __be32  s_feature_ro_compat
  +48  __u8[16] s_uuid
  +64  __be32  s_nr_users
  +68  __be32  s_dynsuper
  +72  __be32  s_max_transaction
  +76  __be32  s_max_trans_data

BLOCK TAG v2 (12 bytes) - In descriptor blocks
  +0  __be32  t_blocknr        Filesystem block (lower 32)
  +4  __be16  t_checksum       CRC32C (truncated)
  +6  __be16  t_flags          0x1=ESCAPE, 0x8=LAST_TAG
  +8  __be32  t_blocknr_high   Upper 32 bits

BLOCK TAG v3 (16 bytes) - With CSUM_V3
  +0  __be32  t_blocknr        Filesystem block (lower 32)
  +4  __be32  t_flags          Flags
  +8  __be32  t_blocknr_high   Upper 32 bits
  +12 __be32  t_checksum       Full CRC32C

COMMIT HEADER (60 bytes)
  +0  journal_header_t
  +12 __u8    h_chksum_type    1=CRC32C
  +13 __u8    h_chksum_size    Size in u32 words
  +16 __be32[8] h_chksum       Transaction checksum
  +48 __be64  h_commit_sec     Timestamp seconds
  +56 __be32  h_commit_nsec    Timestamp nanoseconds

REVOKE HEADER (16 bytes)
  +0  journal_header_t
  +12 __be32  r_count          Bytes used in block
  +16 __be64[] revoked_blocks  Array of block numbers

═══════════════════════════════════════════════════════════════
EOF
            ;;
        9)
            echo
            echo -e "${GREEN}Goodbye!${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid choice${NC}"
            ;;
    esac

    read -p "Press ENTER to continue..."
done
