#!/bin/bash
#
# Interactive Ext4 Journal Explorer
# Educational tool to understand journal layout, transactions, and recovery
#
# Author: Claude AI Assistant
# Purpose: Step-by-step journal internals learning

set -e

# Colors for better readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Configuration
IMG_FILE="/tmp/journal_test.img"
MOUNT_POINT="/tmp/journal_mnt"
IMG_SIZE_MB=100
JOURNAL_SIZE=8  # MB

# Cleanup function
cleanup() {
    echo -e "\n${YELLOW}Cleaning up...${NC}"
    umount "$MOUNT_POINT" 2>/dev/null || true
    losetup -d "$LOOP_DEV" 2>/dev/null || true
    rm -rf "$MOUNT_POINT"
    rm -f "$IMG_FILE"
}

# Print header
print_header() {
    clear
    echo -e "${BOLD}${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║       EXT4 JOURNAL EXPLORER - INTERACTIVE LEARNING        ║${NC}"
    echo -e "${BOLD}${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo
}

# Wait for user to continue
wait_for_user() {
    echo -e "\n${YELLOW}Press ENTER to continue...${NC}"
    read
}

# Print section header
section_header() {
    echo -e "\n${BOLD}${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${MAGENTA}  $1${NC}"
    echo -e "${BOLD}${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

# Step function
step() {
    echo -e "${BOLD}${GREEN}[STEP $CURRENT_STEP]${NC} ${BOLD}$1${NC}"
    CURRENT_STEP=$((CURRENT_STEP + 1))
}

# Info box
info_box() {
    echo -e "${BLUE}╔═══ INFO ═══════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC} $1"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════╝${NC}"
}

# Data structure display
show_structure() {
    echo -e "${CYAN}┌─── DATA STRUCTURE ─────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│${NC}"
    while IFS= read -r line; do
        echo -e "${CYAN}│${NC} $line"
    done
    echo -e "${CYAN}└────────────────────────────────────────────────────────────┘${NC}"
}

# Initialize
CURRENT_STEP=1

print_header
echo -e "${BOLD}This interactive script will help you understand:${NC}"
echo -e "  ${GREEN}✓${NC} Journal layout and structure"
echo -e "  ${GREEN}✓${NC} Transaction lifecycle"
echo -e "  ${GREEN}✓${NC} Data structures (superblock, descriptors, commits)"
echo -e "  ${GREEN}✓${NC} Recovery process"
echo -e "  ${GREEN}✓${NC} Journal checkpointing"
echo

trap cleanup EXIT

# ============================================================================
# PHASE 1: SETUP AND JOURNAL CREATION
# ============================================================================

section_header "PHASE 1: FILESYSTEM AND JOURNAL SETUP"

step "Creating test filesystem image (${IMG_SIZE_MB}MB)"
dd if=/dev/zero of="$IMG_FILE" bs=1M count=$IMG_SIZE_MB status=progress
echo -e "${GREEN}✓ Image created${NC}"
wait_for_user

step "Creating ext4 filesystem with journal"
info_box "We'll create an ext4 filesystem with a ${JOURNAL_SIZE}MB journal"
./misc/mke2fs -t ext4 -J size=$JOURNAL_SIZE -F "$IMG_FILE"
echo -e "${GREEN}✓ Filesystem created${NC}"
wait_for_user

step "Examining filesystem features"
echo -e "${CYAN}Filesystem features (note 'has_journal'):${NC}"
./misc/dumpe2fs -h "$IMG_FILE" 2>/dev/null | grep -E "^Filesystem features:"
echo
echo -e "${CYAN}Journal information:${NC}"
./misc/dumpe2fs "$IMG_FILE" 2>/dev/null | grep -A 20 "^Journal"
wait_for_user

# ============================================================================
# PHASE 2: JOURNAL SUPERBLOCK ANALYSIS
# ============================================================================

section_header "PHASE 2: JOURNAL SUPERBLOCK DEEP DIVE"

step "Understanding Journal Superblock Structure"

cat << 'EOF' | show_structure
Journal Superblock (journal_superblock_t):

typedef struct journal_superblock_s {
    /* Static information describing the journal */
    __be32  h_magic;           /* Magic: 0xc03b3998 */
    __be32  h_blocktype;       /* Type: JBD2_SUPERBLOCK_V2 (4) */
    __be32  h_sequence;        /* First commit ID expected */

    __be32  s_blocksize;       /* Journal block size */
    __be32  s_maxlen;          /* Total blocks in journal */
    __be32  s_first;           /* First block of log info */

    /* Dynamic information describing current state */
    __be32  s_sequence;        /* First commit ID expected in log */
    __be32  s_start;           /* Block number of start of log */

    __be32  s_errno;           /* Error value (if any) */

    /* Feature compatibility flags */
    __be32  s_feature_compat;      /* Compatible features */
    __be32  s_feature_incompat;    /* Incompatible features */
    __be32  s_feature_ro_compat;   /* RO-compatible features */

    __u8    s_uuid[16];        /* 128-bit journal UUID */
    __be32  s_nr_users;        /* Number of filesystems sharing */
    __be32  s_dynsuper;        /* Dynamic superblock copy block */

    __be32  s_max_transaction; /* Max blocks per transaction */
    __be32  s_max_trans_data;  /* Max data blocks in transaction */

    __u8    s_checksum_type;   /* Checksum algorithm (CRC32C) */
    __be32  s_checksum;        /* crc32c(superblock) */
    __be32  s_num_fc_blks;     /* Fast commit blocks */

    __u8    s_users[768];      /* IDs of sharing filesystems */
} journal_superblock_t;
EOF
wait_for_user

step "Dumping actual journal superblock"
info_box "Using debugfs logdump to show journal superblock"
echo
echo -e "${YELLOW}Debugfs command: logdump -s${NC}"
./debugfs/debugfs -R "logdump -s" "$IMG_FILE" 2>/dev/null
wait_for_user

# ============================================================================
# PHASE 3: MOUNTING AND INITIAL OPERATIONS
# ============================================================================

section_header "PHASE 3: MOUNTING FILESYSTEM"

step "Setting up loop device"
LOOP_DEV=$(losetup -f)
losetup "$LOOP_DEV" "$IMG_FILE"
echo -e "${GREEN}✓ Loop device: $LOOP_DEV${NC}"

step "Creating mount point and mounting"
mkdir -p "$MOUNT_POINT"
mount "$LOOP_DEV" "$MOUNT_POINT"
echo -e "${GREEN}✓ Mounted at: $MOUNT_POINT${NC}"
wait_for_user

# ============================================================================
# PHASE 4: TRANSACTION LIFECYCLE
# ============================================================================

section_header "PHASE 4: TRANSACTION LIFECYCLE"

step "Understanding Transaction Structure"

cat << 'EOF' | show_structure
Transaction Anatomy:

1. DESCRIPTOR BLOCK (h_blocktype = 1)
   journal_header_t {
       __be32 h_magic;      /* 0xc03b3998 */
       __be32 h_blocktype;  /* JBD2_DESCRIPTOR_BLOCK (1) */
       __be32 h_sequence;   /* Transaction ID */
   }
   Followed by multiple journal_block_tag_t entries:
   {
       __be32 t_blocknr;      /* Filesystem block number */
       __be16 t_checksum;     /* Block checksum */
       __be16 t_flags;        /* Flags (escape, same_uuid, etc) */
       __be32 t_blocknr_high; /* High 32-bits for 64-bit */
   }

2. METADATA BLOCKS
   - Actual data being written to filesystem
   - One block per tag in descriptor
   - May be escaped if starts with journal magic

3. COMMIT BLOCK (h_blocktype = 2)
   struct commit_header {
       __be32 h_magic;
       __be32 h_blocktype;    /* JBD2_COMMIT_BLOCK (2) */
       __be32 h_sequence;     /* Same transaction ID */
       unsigned char h_chksum_type;
       unsigned char h_chksum_size;
       __be32 h_chksum[8];    /* Transaction checksum */
       __be64 h_commit_sec;   /* Commit timestamp */
       __be32 h_commit_nsec;
   }

4. REVOKE BLOCK (h_blocktype = 5) [Optional]
   journal_revoke_header_t {
       journal_header_t r_header;
       __be32 r_count;        /* Bytes used in block */
   }
   Followed by list of revoked block numbers
EOF
wait_for_user

step "Creating a file to trigger transaction"
info_box "Creating file: $MOUNT_POINT/abc.txt with date command output"
echo
date > "$MOUNT_POINT/abc.txt"
sync
echo -e "${GREEN}✓ File created and sync'd${NC}"
echo
echo -e "${CYAN}File contents:${NC}"
cat "$MOUNT_POINT/abc.txt"
wait_for_user

step "Examining journal after first write"
echo -e "${YELLOW}Full journal dump (first few transactions):${NC}"
echo
umount "$MOUNT_POINT"
./debugfs/debugfs -R "logdump -n 2" "$IMG_FILE" 2>/dev/null | head -100
wait_for_user

step "Understanding what just happened"
info_box "The transaction included: inode allocation, directory entry, data blocks"
echo
echo -e "${CYAN}Transaction components for file creation:${NC}"
echo -e "  1. ${BOLD}Inode bitmap${NC} - Mark inode as used"
echo -e "  2. ${BOLD}Inode table${NC} - Write inode metadata"
echo -e "  3. ${BOLD}Block bitmap${NC} - Mark data blocks as used"
echo -e "  4. ${BOLD}Directory block${NC} - Add 'abc.txt' entry"
echo -e "  5. ${BOLD}Data block${NC} - Write actual file content"
echo -e "  6. ${BOLD}Group descriptors${NC} - Update free inode/block counts"
wait_for_user

# Remount
mount "$LOOP_DEV" "$MOUNT_POINT"

# ============================================================================
# PHASE 5: MULTIPLE TRANSACTIONS
# ============================================================================

section_header "PHASE 5: OBSERVING MULTIPLE TRANSACTIONS"

step "Creating multiple files"
for i in {1..3}; do
    echo "File number $i created at $(date)" > "$MOUNT_POINT/file$i.txt"
    echo -e "${GREEN}✓ Created file$i.txt${NC}"
    sync
    sleep 1
done
wait_for_user

step "Viewing journal with multiple transactions"
umount "$MOUNT_POINT"
echo -e "${YELLOW}Showing all transactions (-n 10):${NC}"
echo
./debugfs/debugfs -R "logdump -n 10" "$IMG_FILE" 2>/dev/null | head -200
wait_for_user

step "Counting transactions and blocks"
echo -e "${CYAN}Transaction statistics:${NC}"
echo
JOURNAL_OUTPUT=$(./debugfs/debugfs -R "logdump -a" "$IMG_FILE" 2>/dev/null)
echo "$JOURNAL_OUTPUT" | grep -c "^Journal starts at block" || echo "Journal entries found"
echo
echo -e "${CYAN}Descriptor blocks:${NC}"
echo "$JOURNAL_OUTPUT" | grep -c "Descriptor block" || echo "0"
echo
echo -e "${CYAN}Commit blocks:${NC}"
echo "$JOURNAL_OUTPUT" | grep -c "Commit block" || echo "0"
wait_for_user

# ============================================================================
# PHASE 6: RECOVERY SIMULATION
# ============================================================================

section_header "PHASE 6: CRASH RECOVERY SIMULATION"

step "Understanding recovery process"
cat << 'EOF' | show_structure
Recovery Process (from e2fsck/recovery.c):

Phase 1: SCAN
  - Find journal superblock
  - Read s_start (where to start recovery)
  - Read s_sequence (expected transaction ID)
  - Scan forward through journal to find last valid commit

Phase 2: REVOKE PROCESSING
  - Build revoke table from revoke blocks
  - Blocks in revoke table won't be replayed
  - Prevents replaying blocks that were later deleted

Phase 3: REPLAY
  - For each transaction with valid commit:
    a. Read descriptor block
    b. For each block tag in descriptor:
       - Check if block is in revoke table
       - If not revoked, write metadata block to filesystem
    c. Verify commit block
  - Update journal superblock s_start

Phase 4: CHECKPOINT
  - Mark recovery complete
  - Update journal superblock
  - Clear s_errno field
EOF
wait_for_user

mount "$LOOP_DEV" "$MOUNT_POINT"

step "Creating a file before simulated crash"
echo "Data before crash: $(date)" > "$MOUNT_POINT/before_crash.txt"
echo -e "${GREEN}✓ Created before_crash.txt${NC}"
sync
wait_for_user

step "Creating a file with uncommitted transaction"
info_box "We'll create a file but crash before journal commit completes"
echo
echo "Data during crash: $(date)" > "$MOUNT_POINT/during_crash.txt"
# Don't sync - simulate crash
echo -e "${YELLOW}⚠ File created but not sync'd (simulated crash)${NC}"
wait_for_user

step "Unmounting (crash simulation)"
umount "$MOUNT_POINT"
echo -e "${RED}✗ Simulated crash - dirty unmount${NC}"
wait_for_user

step "Examining journal state after crash"
echo -e "${CYAN}Journal superblock shows uncommitted transactions:${NC}"
echo
./debugfs/debugfs -R "logdump -s" "$IMG_FILE" 2>/dev/null
wait_for_user

step "Running recovery (e2fsck)"
info_box "e2fsck will replay journal transactions"
echo
./e2fsck/e2fsck -fy "$IMG_FILE"
echo
echo -e "${GREEN}✓ Recovery complete${NC}"
wait_for_user

step "Verifying recovered filesystem"
mount "$LOOP_DEV" "$MOUNT_POINT"
echo -e "${CYAN}Files after recovery:${NC}"
ls -lh "$MOUNT_POINT"
echo
echo -e "${CYAN}Checking if during_crash.txt was recovered:${NC}"
if [ -f "$MOUNT_POINT/during_crash.txt" ]; then
    echo -e "${GREEN}✓ File recovered${NC}"
    cat "$MOUNT_POINT/during_crash.txt"
else
    echo -e "${YELLOW}✗ File not recovered (transaction didn't commit)${NC}"
fi
wait_for_user

# ============================================================================
# PHASE 7: REVOKE BLOCKS
# ============================================================================

section_header "PHASE 7: REVOKE BLOCKS AND DELETION"

step "Understanding revoke blocks"
cat << 'EOF' | show_structure
Revoke Block Purpose:

When you delete a file, its metadata blocks are added to the
journal's revoke list. During recovery, revoked blocks are NOT
replayed, even if they appear in earlier transactions.

Structure:
typedef struct journal_revoke_header_s {
    journal_header_t r_header;  /* Magic, type=5, sequence */
    __be32 r_count;             /* Bytes used in this block */
} jbd2_journal_revoke_header_t;

Followed by array of __be64 block numbers to revoke.

Why needed?
- Transaction T1: Allocate block 1000 for file A
- Transaction T2: Delete file A, revoke block 1000
- Transaction T3: Allocate block 1000 for file B
- If crash before T3 commits but after T2 commits:
  - Without revoke: T1 would replay, overwriting B's data
  - With revoke: T1's write to block 1000 is skipped
EOF
wait_for_user

step "Creating and deleting files to generate revoke blocks"
echo "Temporary file" > "$MOUNT_POINT/temp1.txt"
echo "Temporary file" > "$MOUNT_POINT/temp2.txt"
sync
echo -e "${GREEN}✓ Created temp files${NC}"
sleep 1
rm "$MOUNT_POINT/temp1.txt"
rm "$MOUNT_POINT/temp2.txt"
sync
echo -e "${GREEN}✓ Deleted temp files${NC}"
wait_for_user

step "Looking for revoke blocks in journal"
umount "$MOUNT_POINT"
echo -e "${CYAN}Searching for revoke blocks:${NC}"
echo
./debugfs/debugfs -R "logdump -a" "$IMG_FILE" 2>/dev/null | grep -A 5 -i "revoke"
wait_for_user

# ============================================================================
# PHASE 8: CHECKPOINTING
# ============================================================================

section_header "PHASE 8: JOURNAL CHECKPOINTING"

step "Understanding checkpointing"
info_box "Checkpointing: Moving committed transactions from journal to filesystem"
echo
cat << 'EOF' | show_structure
Checkpoint Process:

1. Transaction T1 commits to journal
2. Later, T1's changes are written to main filesystem
3. Once T1 is safely on disk, it's "checkpointed"
4. Journal superblock s_start moves forward
5. Old journal space can be reused (circular buffer)

Journal acts as circular buffer:
 ┌─────────────────────────────────┐
 │ T1 T2 T3 [  ] [  ] [  ] [  ]    │
 │ ^old  ^new                       │
 └─────────────────────────────────┘

After checkpoint of T1:
 ┌─────────────────────────────────┐
 │ [  ] T2 T3 [  ] [  ] [  ] [  ]  │
 │      ^old  ^new                  │
 └─────────────────────────────────┘

s_start points to oldest uncommitted transaction
s_sequence is transaction ID at s_start
EOF
wait_for_user

step "Viewing journal wrap-around behavior"
mount "$LOOP_DEV" "$MOUNT_POINT"
echo -e "${CYAN}Creating many transactions to observe journal wrap:${NC}"
for i in {1..10}; do
    echo "Transaction $i at $(date)" > "$MOUNT_POINT/txn_$i.txt"
    sync
    echo -e "${GREEN}✓ Transaction $i${NC}"
done
umount "$MOUNT_POINT"
wait_for_user

step "Examining journal space usage"
echo -e "${CYAN}Journal superblock after many transactions:${NC}"
echo
./debugfs/debugfs -R "logdump -s" "$IMG_FILE" 2>/dev/null
echo
info_box "Note s_start field - shows where oldest transaction begins"
wait_for_user

# ============================================================================
# PHASE 9: CHECKSUMS AND DATA INTEGRITY
# ============================================================================

section_header "PHASE 9: CHECKSUMS AND DATA INTEGRITY"

step "Understanding journal checksums"
cat << 'EOF' | show_structure
Checksum Types:

1. JBD2_FEATURE_COMPAT_CHECKSUM (v1)
   - Simple checksum of metadata blocks
   - Stored in block tags

2. JBD2_FEATURE_INCOMPAT_CSUM_V2/V3
   - CRC32C checksums
   - More robust error detection
   - Checksums for:
     * Descriptor blocks (in tail)
     * Commit blocks (in header)
     * Revoke blocks (in tail)
     * Data blocks (in tags)

Commit Block Checksum Calculation:
  - Hash all transaction metadata
  - Include: descriptor blocks, metadata blocks, revoke blocks
  - Stored in commit_header.h_chksum[]
  - Verified during recovery

If checksum fails:
  - Transaction considered incomplete
  - Won't be replayed during recovery
  - Ensures atomic transaction commits
EOF
wait_for_user

step "Checking journal checksum features"
./misc/dumpe2fs -h "$IMG_FILE" 2>/dev/null | grep -i checksum
wait_for_user

# ============================================================================
# PHASE 10: ADVANCED TOPICS
# ============================================================================

section_header "PHASE 10: ADVANCED JOURNAL FEATURES"

step "Fast Commit (EXT4_FEATURE_COMPAT_FAST_COMMIT)"
cat << 'EOF' | show_structure
Fast Commit Optimization:

Traditional journaling:
  - Journal ALL modified metadata blocks
  - Large overhead for small changes

Fast commit:
  - Journal only DELTA (what changed)
  - Much smaller journal entries
  - Tags: ADD_RANGE, DEL_RANGE, CREAT, LINK, UNLINK, INODE

Example:
  Traditional: Journal entire 4KB inode table block
  Fast commit: Journal only changed inode fields (few bytes)

Trade-off:
  + Smaller journal, faster commits
  - More complex recovery logic
  - Fallback to full commit if too many changes
EOF
wait_for_user

step "Journal in ordered vs writeback mode"
info_box "Ext4 has three journaling modes"
echo
cat << 'EOF'
1. data=journal
   - Both metadata AND data written to journal
   - Safest but slowest
   - Guarantees: metadata + data consistency

2. data=ordered (DEFAULT)
   - Metadata journaled
   - Data written to filesystem before commit
   - Guarantees: metadata consistency + no garbage data
   - Best balance of safety and performance

3. data=writeback
   - Only metadata journaled
   - Data written anytime (before/after commit)
   - Fastest but least safe
   - Guarantees: metadata consistency only
   - May see old data in newly allocated blocks after crash
EOF
wait_for_user

# ============================================================================
# PHASE 11: INTERACTIVE EXPLORATION
# ============================================================================

section_header "PHASE 11: INTERACTIVE EXPLORATION WITH DEBUGFS"

step "Launching debugfs for manual exploration"
info_box "Useful debugfs commands for journal exploration"
echo
cat << 'EOF'
Key debugfs commands:

  logdump -s              Show journal superblock
  logdump -a              Dump all journal entries
  logdump -n N            Dump N transactions
  logdump -b BLOCK        Show transactions referencing BLOCK
  logdump -O              Dump old (checkpointed) entries

  stat <inode>            Show inode details
  blocks <inode>          List blocks used by inode
  imap <file>             Show inode number for file

  show_super_stats        Detailed superblock info
  stats                   Filesystem statistics

Type 'quit' to exit debugfs when done.
EOF
echo
echo -e "${YELLOW}Launching debugfs... (type 'quit' when done)${NC}"
echo
./debugfs/debugfs "$IMG_FILE"
wait_for_user

# ============================================================================
# PHASE 12: SUMMARY
# ============================================================================

section_header "PHASE 12: SUMMARY AND KEY TAKEAWAYS"

step "Key Concepts Review"
echo -e "${BOLD}${GREEN}✓ Journal Superblock${NC}"
echo "  - Contains journal metadata and configuration"
echo "  - s_start: where to begin recovery"
echo "  - s_sequence: expected transaction ID"
echo
echo -e "${BOLD}${GREEN}✓ Transaction Lifecycle${NC}"
echo "  1. Descriptor block (defines what's being written)"
echo "  2. Metadata blocks (actual data)"
echo "  3. Commit block (marks transaction complete)"
echo
echo -e "${BOLD}${GREEN}✓ Recovery Process${NC}"
echo "  1. Scan journal for valid transactions"
echo "  2. Build revoke table"
echo "  3. Replay committed transactions"
echo "  4. Update journal superblock"
echo
echo -e "${BOLD}${GREEN}✓ Revoke Blocks${NC}"
echo "  - Prevent replaying deleted blocks"
echo "  - Critical for delete operations"
echo
echo -e "${BOLD}${GREEN}✓ Checkpointing${NC}"
echo "  - Moves transactions from journal to filesystem"
echo "  - Frees journal space for reuse"
echo "  - Journal is circular buffer"
echo
echo -e "${BOLD}${GREEN}✓ Checksums${NC}"
echo "  - Ensure transaction integrity"
echo "  - Detect corruption"
echo "  - Guarantee atomic commits"
echo
wait_for_user

step "Further Exploration"
echo -e "${CYAN}Source files to explore:${NC}"
echo "  • lib/ext2fs/kernel-jbd.h    - Journal data structures"
echo "  • e2fsck/recovery.c          - Recovery algorithm"
echo "  • e2fsck/revoke.c            - Revoke management"
echo "  • debugfs/logdump.c          - Journal dump implementation"
echo "  • lib/ext2fs/mkjournal.c     - Journal creation"
echo
echo -e "${CYAN}Tools for journal analysis:${NC}"
echo "  • dumpe2fs                   - Show filesystem/journal info"
echo "  • debugfs                    - Interactive filesystem debug"
echo "  • e2fsck                     - Filesystem check and recovery"
echo
wait_for_user

print_header
echo -e "${BOLD}${GREEN}Congratulations!${NC}"
echo
echo "You've completed the Ext4 Journal Explorer tutorial!"
echo
echo -e "${CYAN}What you've learned:${NC}"
echo "  ✓ Journal superblock structure"
echo "  ✓ Transaction anatomy (descriptor, metadata, commit)"
echo "  ✓ Transaction lifecycle from creation to checkpoint"
echo "  ✓ Recovery process and crash resilience"
echo "  ✓ Revoke blocks and their purpose"
echo "  ✓ Checkpointing and journal wrap-around"
echo "  ✓ Checksums and data integrity"
echo "  ✓ Fast commits and optimization"
echo
echo -e "${YELLOW}Next steps:${NC}"
echo "  - Explore the source code in e2fsprogs"
echo "  - Experiment with different journal sizes"
echo "  - Try different mount options (data=journal, data=writeback)"
echo "  - Study recovery.c for detailed recovery logic"
echo
echo -e "${BOLD}${CYAN}Thank you for using the Journal Explorer!${NC}"
echo

# Cleanup happens via trap
