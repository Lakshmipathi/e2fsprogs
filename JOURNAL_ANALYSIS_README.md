# Journal Analysis Tools - Parse and Trace

Advanced tools for parsing journal superblock fields and tracing file blocks through journal transactions.

## New Tools

### 1. journal_parser.sh - Parse and Explain Journal Contents

**Purpose**: Parse journal superblock with detailed field explanations and trace specific files through journal transactions.

**Features**:
- ✅ Parses every journal superblock field with explanations
- ✅ Traces file blocks through journal transactions
- ✅ Shows which transactions modified which blocks
- ✅ Maps file operations to journal entries
- ✅ Saves all output to files for review
- ✅ Advanced statistics and analysis

**Usage**:
```bash
# Parse journal superblock only
./journal_parser.sh /path/to/filesystem.img

# Parse journal AND trace a specific file
./journal_parser.sh /path/to/filesystem.img abc.txt
```

**Example Output**:
```
━━━ JOURNAL SUPERBLOCK ANALYSIS ━━━━━━━━━━━━━━━━━━━━━

Journal Start Block: 1
  → Physical block where journal begins on disk
  → Usually block 1 for inline journals

Journal Sequence: 0x00000003
  → Transaction ID of first expected transaction
  → Increments with each committed transaction

Journal Start (s_start): 0
  → Block offset where recovery should begin
  → Points to oldest uncommitted transaction
  → Updated after successful checkpoint

Max Length (s_maxlen): 8192 blocks
  → Total size of journal in blocks
  → Journal wraps around when full (circular buffer)

...

━━━ FILE BLOCK TRACER: abc.txt ━━━━━━━━━━━━━━━━━━━━━━

File: abc.txt
Inode: 13

File blocks used by abc.txt:
  Block 2048
  Block 2049

JOURNAL TRANSACTIONS REFERENCING FILE BLOCKS:

Transaction 2:
  → Block 2048: tag 0: flags 0x0 data 2048
  → Descriptor: inode table modification

Transaction 2:
  → Block 2049: tag 1: flags 0x0 data 2049
  → Descriptor: data block write
```

### 2. journal_explorer_enhanced.sh - Interactive Tutorial with Analysis

**Purpose**: Enhanced version of journal_explorer.sh that automatically parses journal fields and traces the abc.txt file it creates.

**Features**:
- ✅ All features of original journal_explorer.sh
- ✅ Automatically explains every journal superblock field
- ✅ Traces abc.txt blocks through journal
- ✅ Compares journal state before/after operations
- ✅ Saves all analysis to timestamped output directory
- ✅ Shows transaction breakdown

**Usage**:
```bash
sudo ./journal_explorer_enhanced.sh
```

**What It Does**:
1. Creates test filesystem
2. Dumps and explains initial journal state
3. Creates file abc.txt
4. Traces abc.txt blocks through journal
5. Compares journal before/after
6. Breaks down transaction structure
7. Saves everything to files

**Output Files Generated**:
```
/tmp/journal_output_<pid>/
  01_superblock_initial.txt      - Journal state before operations
  02_abc_file_info.txt            - File inode and block info
  03_superblock_after_create.txt  - Journal state after file creation
  04_full_journal_dump.txt        - Complete journal dump
  05_block_trace.txt              - Block-by-block trace results
  06_transaction_analysis.txt     - Transaction statistics
```

---

## Journal Superblock Fields Explained

### Static Information

| Field | Type | Description |
|-------|------|-------------|
| **h_magic** | `__be32` | Magic number: `0xc03b3998` - Identifies journal |
| **s_blocksize** | `__be32` | Journal block size (usually 4096 bytes) |
| **s_maxlen** | `__be32` | Total blocks in journal (circular buffer size) |
| **s_first** | `__be32` | First block of log information (usually 1) |

### Dynamic Information

| Field | Type | Description |
|-------|------|-------------|
| **s_sequence** | `__be32` | Transaction ID counter - increments with each commit |
| **s_start** | `__be32` | Block offset where recovery begins (0 = clean) |
| **s_errno** | `__s32` | Error value if journal has errors (0 = no errors) |

### Feature Flags

| Field | Flags | Description |
|-------|-------|-------------|
| **s_feature_compat** | `0x1` | `JBD2_FEATURE_COMPAT_CHECKSUM` - Journal checksums |
| **s_feature_incompat** | `0x1` | `JBD2_FEATURE_INCOMPAT_REVOKE` - Block revocation |
| | `0x2` | `JBD2_FEATURE_INCOMPAT_64BIT` - 64-bit block numbers |
| | `0x8` | `JBD2_FEATURE_INCOMPAT_CSUM_V2` - Checksum v2 |
| | `0x10` | `JBD2_FEATURE_INCOMPAT_CSUM_V3` - Checksum v3 (CRC32C) |
| | `0x20` | `JBD2_FEATURE_INCOMPAT_FAST_COMMIT` - Fast commits |

### Identity and Limits

| Field | Type | Description |
|-------|------|-------------|
| **s_uuid** | `__u8[16]` | 128-bit journal UUID (must match filesystem) |
| **s_nr_users** | `__be32` | Number of filesystems sharing journal |
| **s_max_transaction** | `__be32` | Max blocks per transaction |
| **s_max_trans_data** | `__be32` | Max data blocks per transaction |

---

## Block Tracing Methodology

### How It Works

1. **Get File Inode**:
   ```bash
   ncheck abc.txt  # Returns inode number
   ```

2. **Get Block Numbers**:
   ```bash
   stat <inode>  # Shows BLOCKS field with allocated blocks
   ```

3. **Search Journal**:
   ```bash
   logdump -a    # Dump all journal transactions
   # Parse for references to our block numbers
   ```

4. **Match Blocks to Transactions**:
   - Descriptor blocks contain block tags
   - Each tag maps journal block → filesystem block
   - Find tags referencing our file's blocks

### Example Trace

```
File: abc.txt
Inode: 13
Blocks: 2048, 2049

Transaction 2 (sequence 0x00000002):
  Descriptor Block at journal offset 10
    Tag 0: fsblock=2048 (inode table)
    Tag 1: fsblock=2049 (data block)
  Metadata Block 1: <inode table data>
  Metadata Block 2: <file content>
  Commit Block: checksum=0x1234abcd

Result: abc.txt data was written in transaction 2
```

---

## Understanding Journal Layout

### Journal Structure

```
┌─────────────────────────────────────────┐
│ Block 0: Journal Superblock             │
│   - Magic: 0xc03b3998                   │
│   - s_sequence, s_start, s_maxlen       │
├─────────────────────────────────────────┤
│ Block 1-N: Transaction Log (Circular)   │
│                                         │
│   Transaction 1:                        │
│     • Descriptor Block (h_blocktype=1)  │
│         - Block tags (fsblock mappings) │
│     • Metadata Block(s)                 │
│         - Actual data being written     │
│     • Commit Block (h_blocktype=2)      │
│         - Transaction checksum          │
│                                         │
│   Transaction 2:                        │
│     • Descriptor Block                  │
│     • Metadata Block(s)                 │
│     • Revoke Block (h_blocktype=5)      │
│         - Deleted block numbers         │
│     • Commit Block                      │
│                                         │
│   ...more transactions...               │
└─────────────────────────────────────────┘
```

### Transaction Anatomy

Each transaction has this structure:

```
[Descriptor] → [Metadata₁] [Metadata₂] ... [MetadataN] → [Commit]
     ↓              ↓           ↓                ↓            ↓
  Lists what    Actual      Actual           Actual      Atomic
  to write     inode data   dir data         data      commit point
```

**Descriptor Block**:
- Lists filesystem block numbers being modified
- Each "tag" maps: journal block → filesystem block
- Flags indicate block type (escaped, deleted, etc.)

**Metadata Blocks**:
- Actual data being written to filesystem
- One metadata block per tag in descriptor
- Could be: inodes, directories, data, bitmaps

**Commit Block**:
- Marks transaction as complete
- Contains transaction checksum (CRC32C)
- Only transactions with valid commits are replayed

---

## Use Cases

### 1. Debug File System Corruption

```bash
# Find which transaction modified a specific block
./journal_parser.sh /dev/sda1 | grep "Block 12345"

# Trace when a file was last modified
./journal_parser.sh /dev/sda1 important.txt
```

### 2. Understand Transaction Flow

```bash
# See exactly what happens when creating a file
sudo ./journal_explorer_enhanced.sh

# Review saved transaction breakdown
cat /tmp/journal_output_*/06_transaction_analysis.txt
```

### 3. Study Recovery Process

```bash
# Check s_start and s_sequence to see if recovery needed
./journal_parser.sh /dev/sda1 | grep "s_start"
./journal_parser.sh /dev/sda1 | grep "s_sequence"

# If s_start ≠ 0, there are uncommitted transactions
```

### 4. Analyze Journal Performance

```bash
# Count transaction types
./journal_parser.sh /dev/sda1 | grep "Descriptor blocks"
./journal_parser.sh /dev/sda1 | grep "Commit blocks"

# Check journal utilization
./journal_parser.sh /dev/sda1 | grep "s_maxlen"
./journal_parser.sh /dev/sda1 | grep "s_start"
```

---

## Advanced Topics

### Why Blocks Might Not Be in Journal

If `journal_parser.sh` doesn't find file blocks in journal:

1. **Checkpointed**: Transaction already written to filesystem
   - Journal wraps around, old entries overwritten
   - Check: `s_start` moved forward

2. **Inline Data**: Small files stored in inode
   - No separate data blocks allocated
   - Check: `stat <inode>` BLOCKS field

3. **Direct I/O**: Bypassed journal
   - Special mount options (data=writeback)
   - Data not journaled, only metadata

4. **Journal Wrapped**: Older transactions overwritten
   - Journal is circular buffer
   - Size limited by `s_maxlen`

### Transaction Ordering

Transactions are ordered by sequence number:

```
s_sequence = 5    (next expected transaction)
s_start = 100     (journal block offset where seq 5 begins)

Recovery will:
1. Start reading from block 100
2. Expect to find transaction with sequence 5
3. Replay transactions 5, 6, 7, ... until end
4. Skip any with missing commit blocks
```

### Revoke Blocks

When files are deleted:

```
Transaction 10:
  Descriptor: allocate block 2000 for file A

Transaction 15:
  Revoke: block 2000 (file A deleted)

Transaction 20:
  Descriptor: allocate block 2000 for file B

Recovery:
- Won't replay transaction 10's write to block 2000
- Revoke list prevents old data from overwriting new file B
```

---

## Integration with Original Tools

These new tools **complement** the existing journal explorer scripts:

| Tool | Purpose | Output |
|------|---------|--------|
| `journal_explorer.sh` | Interactive learning | Terminal |
| `journal_block_inspector.sh` | Deep analysis | Terminal + interactive |
| `journal_recovery_scenarios.sh` | Crash testing | Terminal |
| **`journal_parser.sh`** ⭐ | **Parse & explain** | **Files** |
| **`journal_explorer_enhanced.sh`** ⭐ | **Tutorial + files** | **Both** |

### Workflow Example

```bash
# 1. Learn the concepts interactively
sudo ./journal_explorer.sh

# 2. Deep dive with file saving
sudo ./journal_explorer_enhanced.sh

# 3. Analyze your own filesystem
./journal_parser.sh /dev/sda1

# 4. Trace a specific file
./journal_parser.sh /dev/sda1 /home/user/important.doc

# 5. Review saved analysis
cat /tmp/journal_output_*/05_block_trace.txt
```

---

## Troubleshooting

### "File not found in filesystem"

```bash
# Check file exists
ls -li /mount/point/abc.txt

# Mount filesystem if needed
mount /dev/loop0 /mnt

# Verify with debugfs
debugfs -R "ls -l" /dev/loop0
```

### "No journal transactions found"

**Causes**:
- Filesystem has no journal: `tune2fs -l /dev/sda1 | grep has_journal`
- Journal is external: Check for separate journal device
- All transactions checkpointed: `logdump -s` shows `s_start=0`

**Solutions**:
```bash
# Check journal exists
dumpe2fs -h /dev/sda1 2>/dev/null | grep -i journal

# Force journal activity
mount /dev/sda1 /mnt
echo "test" > /mnt/testfile
sync
umount /mnt
```

### "Permission denied"

```bash
# Need root for block devices
sudo ./journal_parser.sh /dev/sda1

# Or use filesystem images
./journal_parser.sh /tmp/test.img
```

---

## Source Code References

Key functions for understanding the implementation:

| File | Function | Purpose |
|------|----------|---------|
| `e2fsck/recovery.c:351` | `jbd2_journal_recover()` | Main recovery logic |
| `e2fsck/recovery.c:481` | `do_one_pass()` | Scan/replay journal |
| `debugfs/logdump.c:650` | `dump_journal()` | Journal dump implementation |
| `lib/ext2fs/kernel-jbd.h:150` | `journal_superblock_t` | Superblock structure |
| `lib/ext2fs/kernel-jbd.h:200` | `journal_block_tag_t` | Block tag structure |

---

## Further Reading

- Linux kernel documentation: `Documentation/filesystems/ext4/journal.rst`
- JBD2 design: "Journaling the Linux ext2fs Filesystem" by Stephen Tweedie
- e2fsprogs source: `lib/ext2fs/kernel-jbd.h` for data structures

---

**Created by**: Claude AI Assistant
**Purpose**: Educational tools for understanding ext4 journaling
**License**: Same as e2fsprogs
