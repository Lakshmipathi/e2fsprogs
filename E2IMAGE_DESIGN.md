# E2IMAGE Design Document

## Executive Summary

This document provides a comprehensive overview of the e2image tool in e2fsprogs and a detailed explanation of ext4 journaling internals. The document is structured to provide both high-level architecture and step-by-step implementation details.

---

## Part 1: E2IMAGE Tool Design

### 1.1 Overview

**e2image** is a utility program that saves critical ext2/ext3/ext4 filesystem metadata to an image file for debugging and recovery purposes. The tool can create different types of images optimized for various use cases.

**Location**: `misc/e2image.c`

### 1.2 Core Functionality

e2image provides three primary modes of operation:

1. **Normal (Metadata-only) Image** - Saves critical filesystem metadata
2. **Raw Image** - Saves all metadata blocks in filesystem order
3. **QCOW2 Image** - Saves metadata in QCOW2 format (sparse, compressed)

### 1.3 Image Types

#### 1.3.1 Normal Image (Default)
```
Image Header Format (struct ext2_image_hdr):
┌────────────────────────────────────────┐
│ magic_number (EXT2_ET_MAGIC_E2IMAGE)  │
│ magic_descriptor ("Ext2 Image 1.0")   │
│ fs_hostname                            │
│ fs_device_name                         │
│ fs_uuid                                │
│ fs_blocksize                           │
│ offset_super (superblock offset)      │
│ offset_inode (inode table offset)     │
│ offset_blockmap (block bitmap offset) │
│ offset_inodemap (inode bitmap offset) │
│ image_time                             │
└────────────────────────────────────────┘
```

**Components Saved**:
- Superblock
- Group descriptors
- Inode table
- Block bitmap
- Inode bitmap

**Code Flow** (misc/e2image.c:237-303):
```
write_image_file()
├── write_header() - Write placeholder header
├── ext2fs_image_super_write() - Write superblock
├── ext2fs_image_inode_write() - Write inode table
├── ext2fs_image_bitmap_write() - Write block bitmap
├── ext2fs_image_bitmap_write() - Write inode bitmap (IMAGER_FLAG_INODEMAP)
└── write_header() - Update header with actual offsets
```

#### 1.3.2 Raw Image Mode (-r flag)

Raw mode saves all filesystem metadata blocks in their actual filesystem positions, creating a sparse image.

**Metadata Blocks Tracked**:
- Superblocks (primary and backups)
- Group descriptor blocks
- Inode table blocks
- Block bitmaps
- Inode bitmaps
- Directory blocks
- Indirect blocks (single, double, triple)
- Extent tree blocks
- Extended attribute blocks

**Algorithm** (misc/e2image.c:1285-1418):
```
write_raw_image_file()
├── ext2fs_allocate_block_bitmap() - Allocate bitmap for metadata blocks
├── mark_table_blocks() - Mark FS tables (super, descriptors, bitmaps, inodes)
├── ext2fs_open_inode_scan() - Scan all inodes
├── For each inode:
│   ├── Mark EA blocks (extended attributes)
│   ├── ext2fs_block_iterate3() - Iterate file blocks
│   │   ├── process_dir_block() - For directories
│   │   └── process_file_block() - For regular files
│   └── Mark indirect/extent blocks
└── output_meta_data_blocks() - Write marked blocks
```

**Block Selection Logic** (misc/e2image.c:375-405):
```c
process_dir_block():
    - Mark ALL directory blocks (data + metadata)
    - If scramble_block_map: mark for name scrambling

process_file_block():
    - Mark indirect blocks (blockcnt < 0)
    - Mark extent tree blocks
    - If all_data flag: mark data blocks too
```

#### 1.3.3 QCOW2 Image Mode (-Q flag)

QCOW2 (QEMU Copy-On-Write version 2) format provides:
- Sparse image support
- Compression
- Snapshot capability
- Efficient storage

**QCOW2 Structure**:
```
┌─────────────────────────────────────────┐
│ QCOW2 Header                            │
│  - magic (QCOW_MAGIC: 0x514649fb)      │
│  - version (2)                          │
│  - cluster_bits                         │
│  - size (virtual disk size)             │
│  - l1_table_offset                      │
│  - l1_size                              │
│  - refcount_table_offset                │
└─────────────────────────────────────────┘
│ L1 Table (Level 1 mapping)              │
│  - Points to L2 tables                  │
└─────────────────────────────────────────┘
│ L2 Tables (Level 2 mapping)             │
│  - Maps clusters to disk offsets        │
└─────────────────────────────────────────┘
│ Refcount Table & Blocks                 │
│  - Tracks cluster reference counts      │
└─────────────────────────────────────────┘
│ Data Clusters                           │
│  - Actual filesystem metadata           │
└─────────────────────────────────────────┘
```

**Implementation** (misc/e2image.c:898-968, 1162-1283):
```
initialize_qcow2_image()
├── Allocate QCOW2 header
├── Calculate cluster size (= fs blocksize)
├── Initialize L1 table
├── Initialize L2 cache
├── Initialize refcount structures
└── Write header

output_qcow2_meta_data_blocks()
├── For each metadata block:
│   ├── add_l2_item() - Add to L2 table
│   ├── update_refcount() - Update refcount
│   └── generic_write() - Write data
├── flush_l2_cache() - Flush L2 tables
├── sync_refcount() - Write refcount tables
└── Write L1 table
```

### 1.4 Special Features

#### 1.4.1 Directory Name Scrambling (-s flag)

Scrambles directory entry names while preserving structure for privacy during debugging.

**Algorithm** (misc/e2image.c:500-560):
```
scramble_dir_block()
├── For each directory entry:
│   ├── Skip "." and ".."
│   ├── Generate unique name based on original length
│   │   name_id[len]++ for uniqueness
│   │   Pattern: "AAA", "AAB", "AAC", etc.
│   └── Overwrite original name
└── Preserve rec_len and file_type
```

#### 1.4.2 Move Mode (-ra -o/-O flags)

Allows in-place metadata movement within a filesystem, useful for resizing operations.

**Safety Features**:
- Handles source_offset < dest_offset (move right)
- Handles source_offset > dest_offset (move left)
- Process in chunks to avoid overwriting
- SIGINT handling with warning

**Algorithm** (misc/e2image.c:615-732):
```
If moving right (dest_offset > source_offset):
    distance = (dest_offset - source_offset) / blocksize
    start = blocks_count - distance
    Process blocks in reverse order
Else:
    Process blocks in forward order
```

#### 1.4.3 Check Mode (-c flag)

Compares image blocks with existing disk blocks, skipping identical blocks.

**Benefits**:
- Faster image creation/update
- Reduced I/O
- Reports skipped blocks

### 1.5 Installation Mode (-I flag)

Restores a metadata image back to a device. Useful for filesystem recovery.

**Code Flow** (misc/e2image.c:1420-1483):
```
install_image()
├── ext2fs_open() - Open image file with EXT2_FLAG_IMAGE_FILE
├── ext2fs_read_bitmaps() - Read bitmaps from image
├── io_ptr->open() - Open target device
├── ext2fs_rewrite_to_io() - Redirect writes to device
├── ext2fs_image_inode_read() - Read inode table from image
└── ext2fs_image_inode_write() - Write to device (via rewrite)
```

---

## Part 2: EXT4 Journal Internals - Complete Step-by-Step Process

### 2.1 Journal Overview

The ext4 journaling subsystem (JBD2 - Journaling Block Device version 2) provides crash consistency through write-ahead logging of filesystem metadata changes.

**Key Concepts**:
- **Transaction**: Group of related metadata changes
- **Commit**: Atomic write of transaction to journal
- **Checkpoint**: Write of committed data to final filesystem locations
- **Recovery**: Replay of committed transactions after crash

### 2.2 Journal Data Structures

#### 2.2.1 Journal Superblock

**Location**: First block of journal (or block 1 for external journal)

**Structure** (`lib/ext2fs/kernel-jbd.h:183-233`):
```c
typedef struct journal_superblock_s {
    /* Static information (offset 0x0000) */
    journal_header_t s_header;          // Magic + blocktype + sequence
    __be32  s_blocksize;                // Journal device blocksize
    __be32  s_maxlen;                   // Total blocks in journal
    __be32  s_first;                    // First block of log information

    /* Dynamic information (offset 0x0018) */
    __be32  s_sequence;                 // First commit ID in log
    __be32  s_start;                    // Block number of start of log

    /* Error value (offset 0x0020) */
    __s32   s_errno;                    // Error value from journal_abort()

    /* Version 2 fields (offset 0x0024) */
    __be32  s_feature_compat;           // Compatible features
    __be32  s_feature_incompat;         // Incompatible features
    __be32  s_feature_ro_compat;        // Read-only compatible features
    __u8    s_uuid[16];                 // 128-bit UUID

    /* Journal users (offset 0x0040) */
    __be32  s_nr_users;                 // Number of filesystems sharing
    __be32  s_dynsuper;                 // Dynamic superblock copy location
    __be32  s_max_transaction;          // Max journal blocks per transaction
    __be32  s_max_trans_data;           // Max data blocks per transaction

    /* Checksumming (offset 0x0050) */
    __u8    s_checksum_type;            // Checksum algorithm
    __be32  s_num_fc_blks;              // Fast commit blocks
    __be32  s_checksum;                 // Superblock checksum

    /* Multiple users (offset 0x0100) */
    __u8    s_users[JBD2_USERS_SIZE];   // IDs of all sharing filesystems
} journal_superblock_t;
```

**Key Fields Explained**:
- `s_start`: Points to first valid transaction in journal (0 = clean unmount)
- `s_sequence`: Transaction ID of first transaction in log
- `s_maxlen`: Total journal size in blocks
- `s_first`: Usually 1 (block 0 is superblock)

#### 2.2.2 Journal Header

Every journal block starts with this header (`lib/ext2fs/kernel-jbd.h:88-93`):
```c
typedef struct journal_header_s {
    __be32  h_magic;        // JBD2_MAGIC_NUMBER (0xc03b3998)
    __be32  h_blocktype;    // Block type (descriptor/commit/super/revoke)
    __be32  h_sequence;     // Transaction sequence number
} journal_header_t;
```

**Block Types**:
- `JBD2_DESCRIPTOR_BLOCK (1)`: Lists blocks in transaction
- `JBD2_COMMIT_BLOCK (2)`: Marks transaction complete
- `JBD2_SUPERBLOCK_V1 (3)`: Version 1 superblock
- `JBD2_SUPERBLOCK_V2 (4)`: Version 2 superblock
- `JBD2_REVOKE_BLOCK (5)`: Lists revoked blocks
- `JBD2_FC_BLOCK (6)`: Fast commit block

#### 2.2.3 Descriptor Block

Describes which filesystem blocks are being journaled in this transaction.

**Structure**:
```c
journal_header_t header;
journal_block_tag_t tags[];     // Array of block descriptors
[optional: jbd2_journal_block_tail]  // Checksum (if checksumming enabled)
```

**Block Tag** (`lib/ext2fs/kernel-jbd.h:139-153`):
```c
// Version 3 (with full checksum)
typedef struct journal_block_tag3_s {
    __be32  t_blocknr;          // Filesystem block number
    __be32  t_flags;            // Flags (escaped, same_uuid, deleted, last)
    __be32  t_blocknr_high;     // High 32 bits (for 64-bit)
    __be32  t_checksum;         // Full 32-bit checksum
} journal_block_tag3_t;

// Version 2 (with 16-bit checksum)
typedef struct journal_block_tag_s {
    __be32  t_blocknr;          // Filesystem block number
    __be16  t_checksum;         // Truncated 16-bit checksum
    __be16  t_flags;            // Flags
    __be32  t_blocknr_high;     // High 32 bits
} journal_block_tag_t;
```

**Tag Flags**:
- `JBD2_FLAG_ESCAPE (1)`: Block starts with JBD2_MAGIC, escaped
- `JBD2_FLAG_SAME_UUID (2)`: Same UUID as previous tag (saves space)
- `JBD2_FLAG_DELETED (4)`: Block deleted by transaction
- `JBD2_FLAG_LAST_TAG (8)`: Last tag in descriptor

#### 2.2.4 Commit Block

**Structure** (`lib/ext2fs/kernel-jbd.h:124-134`):
```c
struct commit_header {
    __be32  h_magic;                        // JBD2_MAGIC_NUMBER
    __be32  h_blocktype;                    // JBD2_COMMIT_BLOCK
    __be32  h_sequence;                     // Transaction ID
    unsigned char h_chksum_type;            // Checksum type
    unsigned char h_chksum_size;            // Checksum size
    unsigned char h_padding[2];
    __be32  h_chksum[JBD2_CHECKSUM_BYTES]; // Transaction checksum
    __be64  h_commit_sec;                   // Commit timestamp (seconds)
    __be32  h_commit_nsec;                  // Commit timestamp (nanoseconds)
};
```

#### 2.2.5 Revoke Block

Lists blocks that should not be replayed during recovery.

**Structure** (`lib/ext2fs/kernel-jbd.h:164-168`):
```c
typedef struct journal_revoke_header_s {
    journal_header_t r_header;  // Standard header
    __be32  r_count;            // Bytes used in block
    // Followed by array of __be64 or __be32 block numbers
    // Terminated by jbd2_journal_block_tail (if checksumming)
} jbd2_journal_revoke_header_t;
```

### 2.3 Journal Layout

```
┌────────────────────────────────────────────────────────┐
│ Block 0: Journal Superblock                            │
├────────────────────────────────────────────────────────┤
│ Block 1: Transaction T1 - Descriptor Block 1          │
│          ├─ Tag: FS block 1234 → Journal block 2      │
│          ├─ Tag: FS block 5678 → Journal block 3      │
│          └─ Tag: FS block 9012 → Journal block 4      │
├────────────────────────────────────────────────────────┤
│ Block 2: Data (FS block 1234)                         │
├────────────────────────────────────────────────────────┤
│ Block 3: Data (FS block 5678)                         │
├────────────────────────────────────────────────────────┤
│ Block 4: Data (FS block 9012)                         │
├────────────────────────────────────────────────────────┤
│ Block 5: Transaction T1 - Commit Block                │
├────────────────────────────────────────────────────────┤
│ Block 6: Transaction T2 - Descriptor Block            │
│ ...                                                    │
├────────────────────────────────────────────────────────┤
│ Block N-1: Last block (wraps to block 1)              │
└────────────────────────────────────────────────────────┘
```

**Circular Buffer**: Journal wraps around when reaching the end.

### 2.4 Transaction Lifecycle - Step by Step

#### Step 1: Transaction Creation

When filesystem needs to modify metadata:

1. **Allocate Transaction Handle**
   - Transaction ID (TID) assigned
   - Becomes "running transaction"

2. **Reserve Journal Space**
   - Calculate space needed
   - Ensure enough free blocks in journal

**Code Reference**: Not directly in e2fsprogs (kernel operation)

#### Step 2: Metadata Modification

1. **Get Buffer for Metadata Block**
   - ext2fs reads block into memory

2. **Journal the Buffer**
   - Copy original data to journal buffer
   - Mark buffer as "journaled"

3. **Modify Buffer**
   - Make changes to in-memory copy
   - Mark buffer dirty

**In e2fsck Context** (`e2fsck/journal.c:204-207`):
```c
void mark_buffer_dirty(struct buffer_head *bh) {
    bh->b_dirty = 1;  // Mark for write-back
}
```

#### Step 3: Transaction Commit - Detailed Flow

**Phase 1: Prepare Commit** (`e2fsck/recovery.c:455-500+`):

1. **Stop New Modifications**
   - Close transaction to new operations
   - Create new running transaction for new ops

2. **Wait for Outstanding I/O**
   - All journaled buffers must be in memory

3. **Build Descriptor Blocks**
```
For each journaled buffer:
    If buffer starts with JBD2_MAGIC:
        Set ESCAPE flag in tag
        Write escaped version to journal
    Create journal_block_tag:
        t_blocknr = filesystem block number
        t_flags = escape | same_uuid | last_tag
        If checksumming:
            t_checksum = crc32c(uuid + sequence + block_data)
    Add tag to descriptor block
```

**Phase 2: Write Transaction** (3-phase commit):

**Phase 2a: Write Descriptor + Data Blocks**
```
1. Write descriptor block(s) to journal
2. Write data blocks to journal
3. Wait for I/O completion
```

**Phase 2b: Write Commit Block**
```
1. Create commit block:
   - h_sequence = transaction ID
   - h_chksum = checksum of all blocks in transaction
2. Issue write
3. WAIT for write completion (critical!)
4. Issue flush/barrier (if enabled)
```

**Why the wait is critical**: Once commit block hits disk, transaction is considered complete. If system crashes before, transaction is discarded.

**Phase 2c: Update Journal Superblock**
```
1. Update s_start to point past this transaction
2. Update s_sequence
3. Write superblock
```

**Code Flow** (`e2fsck/journal.c:1467-1497`):
```c
e2fsck_journal_release()
├── If not drop:
│   ├── jsb->s_sequence = htonl(journal->j_tail_sequence)
│   ├── If reset: jsb->s_start = 0  // Mark journal empty
│   ├── e2fsck_journal_sb_csum_set()  // Update checksum
│   └── mark_buffer_dirty()
└── brelse(journal->j_sb_buffer)
```

#### Step 4: Checkpoint

After commit, data must eventually be written to final locations.

**Checkpoint Process**:
```
1. For each block in committed transaction:
    Write buffer to final filesystem location
2. Update journal head pointer
3. Free journal space
```

**Space Reclamation**:
- Journal superblock `s_start` advances
- Old transactions can be overwritten

### 2.5 Recovery Process - Step by Step

Recovery occurs during `fsck` or mount after unclean shutdown.

**Entry Point** (`e2fsck/journal.c:1630-1687`):
```c
recover_ext3_journal()
├── jbd2_journal_init_revoke_record_cache()
├── jbd2_journal_init_revoke_table_cache()
├── e2fsck_get_journal()
├── e2fsck_journal_load()
├── jbd2_journal_init_revoke()
└── jbd2_journal_recover()  // Main recovery
```

#### Step 1: Scan Phase (`e2fsck/recovery.c:306-356`)

**Purpose**: Find valid transactions and build revoke list.

```
Algorithm:
1. Start at s_start from journal superblock
2. Read journal block by block
3. For each block:
    Check magic number (JBD2_MAGIC_NUMBER)
    Check sequence number (must match or increment)

    If DESCRIPTOR_BLOCK:
        Count blocks referenced
        Validate checksums
        Record extent of transaction

    If REVOKE_BLOCK:
        Parse revoke records
        Add to revoke hash table

    If COMMIT_BLOCK:
        Validate commit checksum
        Mark transaction as complete
        Update end_transaction

    If sequence number breaks or invalid:
        Stop scan (found end of valid journal)

4. Record:
    start_transaction = first TID found
    end_transaction = last complete TID
    nr_revokes = blocks in revoke table
```

**Fast Commit Scan** (`e2fsck/journal.c:278-383`):
```
ext4_fc_replay_scan()
├── For each fast commit block:
│   ├── Parse FC tag (ADD_RANGE, DEL_RANGE, LINK, UNLINK, etc.)
│   ├── Update running CRC
│   └── Validate against tail block
└── Return CONTINUE or STOP
```

#### Step 2: Revoke Phase (`e2fsck/recovery.c:307-310`)

**Purpose**: Process all revoke records.

```
Algorithm:
1. Re-scan journal from start_transaction to end_transaction
2. For each REVOKE_BLOCK:
    Read revoke record count
    For each revoked block number:
        jbd2_journal_set_revoke(blocknr, sequence)
            Creates revoke record
            Adds to hash table

3. Revoke table structure:
    Hash table (hash by block number)
    Each entry:
        - blocknr: filesystem block number
        - sequence: transaction that revoked it
```

**Revoke Hash Table** (`e2fsck/revoke.c:131-156`):
```c
insert_revoke_hash()
├── Allocate jbd2_revoke_record_s
│   ├── record->sequence = seq
│   ├── record->blocknr = blocknr
│   └── record->hash = linked list node
├── hash_index = hash_64(blocknr, hash_shift)
└── Add to hash_table[hash_index]
```

#### Step 3: Replay Phase (`e2fsck/recovery.c:310-332`)

**Purpose**: Write committed transactions to filesystem.

```
Detailed Replay Algorithm:
1. Initialize block bitmaps and inode bitmaps
2. Mark filesystem state as "undergoing recovery"
3. For transaction = start_transaction to end_transaction:

    a. Read descriptor block
    b. For each tag in descriptor:

        fs_blocknr = tag->t_blocknr (+ high bits)
        journal_blocknr = next journal block

        Check revoke table:
            If jbd2_journal_test_revoke(fs_blocknr, sequence):
                Skip this block (it was revoked)
                nr_revoke_hits++
                Continue to next tag

        Read block from journal:
            jread(&bh, journal, journal_blocknr)

        Validate checksum:
            If tag has checksum:
                Calculate: crc32c(uuid + sequence + block_data)
                Compare with tag->t_checksum
                If mismatch: abort recovery

        Handle escaping:
            If tag->t_flags & JBD2_FLAG_ESCAPE:
                bh->b_data[0:4] = JBD2_MAGIC_NUMBER

        Write to filesystem:
            Map fs_blocknr to physical location
            Write buffer to disk
            nr_replays++

    c. Read commit block
    d. Validate commit checksum
    e. If valid: transaction successfully replayed
    f. If invalid: stop replay (incomplete transaction)
```

**Replay Code Flow** (`e2fsck/recovery.c:455+`):
```c
do_one_pass(PASS_REPLAY)
├── For each journal block in range:
│   ├── jread() - Read journal block
│   ├── Check block type:
│   │   ├── DESCRIPTOR_BLOCK:
│   │   │   ├── count_tags() - Count blocks to replay
│   │   │   ├── For each tag:
│   │   │   │   ├── Check if revoked
│   │   │   │   ├── jread() data block
│   │   │   │   ├── Verify checksum
│   │   │   │   ├── Handle escape
│   │   │   │   └── Write to fs location
│   │   │   └── Next descriptor
│   │   ├── COMMIT_BLOCK:
│   │   │   ├── Verify commit checksum
│   │   │   └── Transaction complete
│   │   └── REVOKE_BLOCK:
│   │       └── Skip (processed in revoke phase)
│   └── Advance to next block
└── Return success/failure
```

**Fast Commit Replay** (`e2fsck/journal.c:860-957`):
```
ext4_fc_replay()
├── For each FC block:
│   ├── Switch on tag type:
│   │   ├── EXT4_FC_TAG_LINK/CREAT:
│   │   │   └── ext2fs_link() - Create directory entry
│   │   ├── EXT4_FC_TAG_UNLINK:
│   │   │   └── ext2fs_unlink() - Remove directory entry
│   │   ├── EXT4_FC_TAG_INODE:
│   │   │   └── ext2fs_write_inode() - Update inode
│   │   ├── EXT4_FC_TAG_ADD_RANGE:
│   │   │   └── Add extents to file
│   │   └── EXT4_FC_TAG_DEL_RANGE:
│   │       └── Remove extents from file
│   └── Update bitmaps and statistics
└── Flush all changes
```

#### Step 4: Cleanup

```
After successful replay:
1. Recalculate filesystem summary statistics
    ext2fs_calculate_summary_stats()
    Update:
        - Free block count
        - Free inode count
        - Directory count
        - Group descriptor checksums

2. Write updated bitmaps
    ext2fs_write_block_bitmap()
    ext2fs_write_inode_bitmap()

3. Clear recovery flag
    ext2fs_clear_feature_journal_needs_recovery()
    fs->super->s_state &= ~EXT2_ERROR_FS

4. Reset journal superblock
    jsb->s_start = 0  // Journal is now empty
    jsb->s_sequence++  // Next transaction ID

5. Write superblock and flush
    ext2fs_mark_super_dirty()
    ext2fs_flush()
```

### 2.6 Revoke Mechanism Details

**Problem**: A block is modified twice in journal before checkpoint:
```
Transaction T1: Block 1234 = "Version A"
Transaction T2: Block 1234 = "Version B"
Transaction T3: Block 1234 deleted
[Crash before checkpoint]
```

During recovery without revokes:
- Replay T1: Write "Version A" to block 1234
- Replay T2: Write "Version B" to block 1234
- Replay T3: Write deleted version
- Result: Correct

But with early checkpoint:
```
Transaction T1: Block 1234 = "Version A"
[Checkpoint: Block 1234 written to fs]
Transaction T2: Block 1234 = "Version B"
Transaction T3: Block 1234 deleted, revoked
[Crash]
```

Without revoke replay:
- Replay T1: Write "Version A" (WRONG! Should use checkpointed version)
- Result: Data corruption

With revoke replay:
- Scan: Find revoke for block 1234 in T3
- Replay: Skip T1's write to block 1234
- Result: Correct

**Revoke Record Lifetime**:
```c
jbd2_journal_set_revoke(journal, blocknr, sequence)
    Creates hash entry:
        blocknr = 1234
        sequence = 3  // Transaction ID that revoked it

jbd2_journal_test_revoke(journal, blocknr, sequence)
    Look up blocknr in hash
    If found and record->sequence >= sequence:
        return 1  // Skip this block
    return 0  // Replay this block
```

### 2.7 Checksumming

Modern ext4 uses checksums for journal integrity.

#### Checksum Types:
- **JBD2_CRC32C_CHKSUM (4)**: CRC32C (Castagnoli) - most common

#### Checksum Coverage:

**1. Journal Superblock** (`e2fsck/journal.c:51-76`):
```c
e2fsck_journal_sb_csum()
├── old_crc = jsb->s_checksum
├── jsb->s_checksum = 0
├── crc = ext2fs_crc32c_le(~0, jsb, sizeof(journal_superblock_t))
├── jsb->s_checksum = old_crc
└── return crc
```

**2. Descriptor Block** (`e2fsck/jfs_user.h:236-250`):
```c
jbd2_descriptor_block_csum_set()
├── tail = end of descriptor block
├── tail->t_checksum = 0
├── crc = jbd2_chksum(j_csum_seed, block_data, blocksize)
└── tail->t_checksum = cpu_to_be32(crc)
```

**3. Commit Block** (`debugfs/journal.c:886-900`):
```c
jbd2_commit_block_csum_set()
├── Zero out chksum fields in commit header
├── crc = jbd2_chksum(j_csum_seed, block_data, blocksize)
└── h->h_chksum[0] = cpu_to_be32(crc)
```

**4. Block Tag** (`debugfs/journal.c:922-940`):
```c
jbd2_block_tag_csum_set()
├── seq = cpu_to_be32(sequence)
├── crc = jbd2_chksum(j_csum_seed, &seq, sizeof(seq))
├── crc = jbd2_chksum(crc, block_data, blocksize)
└── If CSUM_V3:
    │   tag3->t_checksum = cpu_to_be32(crc)
    └── Else:
        tag->t_checksum = cpu_to_be16(crc)
```

**Checksum Seed** (`e2fsck/journal.c:1354-1356`):
```c
if (jbd2_journal_has_csum_v2or3(journal))
    journal->j_csum_seed = jbd2_chksum(journal, ~0,
                                       jsb->s_uuid,
                                       sizeof(jsb->s_uuid));
```

### 2.8 Fast Commit

Fast commit is an optimization that journals only metadata changes without waiting for full transaction commit.

**Fast Commit Block Types** (`e2fsck/journal.c:319-336`):
- `EXT4_FC_TAG_HEAD`: Start of FC area
- `EXT4_FC_TAG_TAIL`: End of FC area (with CRC)
- `EXT4_FC_TAG_ADD_RANGE`: Add extent to file
- `EXT4_FC_TAG_DEL_RANGE`: Remove extent from file
- `EXT4_FC_TAG_CREAT`: Create directory entry
- `EXT4_FC_TAG_LINK`: Hard link
- `EXT4_FC_TAG_UNLINK`: Remove link
- `EXT4_FC_TAG_INODE`: Update inode
- `EXT4_FC_TAG_PAD`: Padding

**Layout**:
```
┌──────────────────────────────────────┐
│ Normal Journal (blocks 1 to j_last)  │
├──────────────────────────────────────┤
│ FC Area (blocks j_fc_first to        │
│          j_fc_last)                   │
│  ├─ FC_TAG_HEAD                      │
│  ├─ FC_TAG_INODE                     │
│  ├─ FC_TAG_ADD_RANGE                 │
│  ├─ ...                               │
│  └─ FC_TAG_TAIL (with CRC)           │
└──────────────────────────────────────┘
```

**Fast Commit Recovery** (`e2fsck/journal.c:860-957`):
Replays FC tags to quickly recover recent changes without full journal scan.

### 2.9 Journal Features

**Compatible Features** (`lib/ext2fs/kernel-jbd.h:245`):
- `JBD2_FEATURE_COMPAT_CHECKSUM`: Version 1 checksumming

**Incompatible Features** (`lib/ext2fs/kernel-jbd.h:247-252`):
- `JBD2_FEATURE_INCOMPAT_REVOKE`: Revoke support
- `JBD2_FEATURE_INCOMPAT_64BIT`: 64-bit block numbers
- `JBD2_FEATURE_INCOMPAT_ASYNC_COMMIT`: Async commit
- `JBD2_FEATURE_INCOMPAT_CSUM_V2`: Checksum version 2
- `JBD2_FEATURE_INCOMPAT_CSUM_V3`: Checksum version 3
- `JBD2_FEATURE_INCOMPAT_FAST_COMMIT`: Fast commit support

### 2.10 Journal Access from e2fsprogs

#### Reading Journal (`debugfs/journal.c`):

**debugfs commands**:
- `logdump [-acs] [-b block] [-f journal_file]`: Dump journal contents
  - `-a`: Print all blocks
  - `-c`: Print commit blocks
  - `-s`: Print superblock

#### Recovering Journal (`e2fsck`):

**Flow** (`e2fsck/journal.c:1689-1747`):
```c
e2fsck_run_ext3_journal()
├── Save current state
├── recover_ext3_journal()
│   ├── jbd2_journal_recover()
│   │   ├── PASS_SCAN
│   │   ├── PASS_REVOKE
│   │   └── PASS_REPLAY
│   └── Return status
├── Reload filesystem (journal changed it)
│   ├── ext2fs_mmp_stop()
│   ├── ext2fs_free()
│   └── ext2fs_open()
├── Update superblock
│   ├── Clear recovery flag
│   ├── Preserve error state
│   └── ext2fs_flush()
└── e2fsck_check_ext3_journal() - Final check
```

### 2.11 Performance Considerations

**Journal Size**:
- Minimum: 1024 blocks (JBD2_MIN_JOURNAL_BLOCKS)
- Typical: 32 MB - 128 MB
- Large journals allow more outstanding transactions
- Larger journals take longer to recover

**Commit Interval**:
- Default: 5 seconds
- Tradeoff: Latency vs. throughput vs. recovery time

**Barriers**:
- Force write ordering
- Critical for commit block atomicity
- Performance impact on some devices

**Async Commit**:
- Write commit block during data write phase
- Reduces latency
- Requires checksumming

---

## 3. Key Algorithms Summary

### 3.1 Journal Commit Algorithm
```
ALGORITHM: Transaction Commit
INPUT: Transaction T with modified blocks B1, B2, ..., Bn
OUTPUT: Atomically committed transaction in journal

1. PREPARE PHASE:
   a. Close transaction to new operations
   b. Wait for all buffer I/O completion
   c. Assign transaction ID (sequence number)

2. DESCRIPTOR PHASE:
   a. For each block Bi in transaction:
      - Create journal_block_tag for Bi
      - Set blocknr = filesystem block number
      - If block starts with MAGIC: set ESCAPE flag
      - Calculate checksum: CRC32C(UUID || TID || block_data)
      - Set checksum in tag
   b. Write descriptor block(s) to journal
   c. Write data blocks to journal
   d. Wait for all writes to complete

3. COMMIT PHASE:
   a. Create commit block:
      - Set sequence = transaction ID
      - Calculate commit checksum = CRC32C(all blocks)
   b. Write commit block to journal
   c. **WAIT for commit block write completion**
   d. Issue storage barrier/flush

4. FINALIZE PHASE:
   a. Update journal superblock:
      - Increment s_sequence
      - Update s_start if needed
   b. Transaction is now committed
```

### 3.2 Journal Recovery Algorithm
```
ALGORITHM: Journal Recovery
INPUT: Journal with superblock JSB
OUTPUT: Recovered filesystem with all committed transactions replayed

1. SCAN PHASE:
   a. Read journal superblock
   b. If JSB.s_start == 0: journal is clean, exit
   c. Initialize: current_tid = JSB.s_sequence
                  current_block = JSB.s_start

   d. While scanning:
      - Read block at current_block
      - Verify magic number
      - Verify sequence matches or increments

      If DESCRIPTOR_BLOCK:
         Count tags, validate structure

      If COMMIT_BLOCK:
         Validate checksum
         Record transaction as complete
         Update end_transaction = current_tid

      If sequence breaks: end of valid journal

   e. Result: [start_tid, end_tid] range to replay

2. REVOKE PHASE:
   a. Re-scan journal from start_tid to end_tid
   b. For each REVOKE_BLOCK:
      - Parse revoke records
      - For each (blocknr, tid):
         Insert into revoke hash table
         Key = blocknr, Value = tid
   c. Revoke table ready for lookup

3. REPLAY PHASE:
   a. Mark filesystem as "under recovery"
   b. For tid = start_tid to end_tid:

      - Read descriptor block
      - For each tag in descriptor:

         fs_block = tag.t_blocknr
         journal_block = next_journal_block()

         // Check if block is revoked
         IF jbd2_journal_test_revoke(fs_block, tid):
            Skip this block (revoked)
            Continue

         // Read from journal
         Read journal_block into buffer

         // Validate checksum
         IF tag has checksum:
            calculated = CRC32C(UUID || tid || buffer)
            IF calculated != tag.t_checksum:
               Abort recovery (corruption detected)

         // Handle escape
         IF tag.t_flags & ESCAPE:
            buffer[0:4] = JBD2_MAGIC_NUMBER

         // Write to filesystem
         Write buffer to fs_block location

      - Verify commit block checksum
      - Transaction replayed successfully

4. CLEANUP PHASE:
   a. Recalculate filesystem statistics
   b. Write updated bitmaps
   c. Clear recovery flag in superblock
   d. Reset journal: JSB.s_start = 0
   e. Flush all changes to disk
```

### 3.3 Revoke Lookup Algorithm
```
ALGORITHM: Revoke Test
INPUT: Block number B, Transaction ID T
OUTPUT: Boolean - should skip this block?

1. hash_index = HASH(B)
2. linked_list = revoke_table[hash_index]
3. For each record R in linked_list:
   a. If R.blocknr == B:
      - If R.sequence >= T:
         Return TRUE  (block was revoked after or in this transaction)
      - Else:
         Return FALSE (revoke was before this transaction)
4. Return FALSE (block not in revoke table)

Explanation:
- If a block is revoked in transaction T=5
- And we're replaying transaction T=3
- We should NOT skip (T=3 < T=5)
- This means the block was valid in T=3, revoked later in T=5
```

---

## 4. Important Code References

### 4.1 e2image Key Files
- `misc/e2image.c` - Main implementation
- `lib/ext2fs/e2image.h` - Image header structures
- `lib/ext2fs/qcow2.h` - QCOW2 structures

### 4.2 Journal Key Files
- `lib/ext2fs/kernel-jbd.h` - Journal structures (from kernel)
- `e2fsck/jfs_user.h` - Userspace journal compatibility
- `e2fsck/journal.c` - e2fsck journal operations
- `e2fsck/recovery.c` - Recovery implementation
- `e2fsck/revoke.c` - Revoke implementation
- `debugfs/journal.c` - Journal debugging

### 4.3 Critical Functions

**Journal Operations**:
- `e2fsck_run_ext3_journal()` - Main recovery entry
- `jbd2_journal_recover()` - Core recovery logic
- `do_one_pass()` - Single recovery pass (scan/revoke/replay)
- `jbd2_journal_init_revoke()` - Initialize revoke tables

**Journal I/O**:
- `jbd2_journal_bmap()` - Map journal block to physical
- `getblk()` - Get buffer head for block
- `ll_rw_block()` - Low-level block read/write

**Checksums**:
- `jbd2_chksum()` - Calculate CRC32C
- `jbd2_descriptor_block_csum_set()` - Set descriptor checksum
- `jbd2_commit_block_csum_set()` - Set commit checksum
- `jbd2_block_tag_csum_set()` - Set tag checksum

---

## 5. Conclusion

This document provides a comprehensive overview of:

1. **e2image tool**: Its architecture, image formats, and use cases for filesystem metadata backup and debugging

2. **ext4 journal internals**: Complete step-by-step process of:
   - Journal structure and layout
   - Transaction lifecycle from creation to commit
   - Recovery process with three phases (scan, revoke, replay)
   - Revoke mechanism for handling multiply-modified blocks
   - Checksumming for integrity
   - Fast commit optimization

The journaling system is critical for ext4's crash consistency guarantees, and e2image provides essential tools for forensic analysis and recovery of journaled filesystems.

---

## References

1. e2fsprogs source code: https://git.kernel.org/pub/scm/fs/ext2/e2fsprogs.git/
2. JBD2 kernel documentation: Documentation/filesystems/ext4/journal.rst
3. ext4 disk layout: Documentation/filesystems/ext4/
4. QCOW2 specification: https://github.com/qemu/qemu/blob/master/docs/interop/qcow2.txt

---

**Document Version**: 1.0
**Date**: 2025-11-18
**Author**: AI Assistant (Claude)
**Repository**: e2fsprogs
