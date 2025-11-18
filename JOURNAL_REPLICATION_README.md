# Journal-Based Filesystem Replication

This system implements **block-level replication** using ext4's journaling mechanism. It allows you to synchronize filesystem changes between two servers by transferring and replaying journal transactions.

## Concept

Instead of copying files (like rsync), this approach:
1. Captures uncommitted journal transactions from the source
2. Transfers the journal blocks to the replica
3. Triggers journal replay on the replica
4. Results in identical filesystems at the block level

This is similar to how systems like DRBD, MySQL replication, and PostgreSQL streaming replication work.

## Architecture

```
SERVER1 (Source)                    SERVER2 (Replica)
┌─────────────────┐                ┌─────────────────┐
│   fs.img        │                │   fs.img        │
│  ┌───────────┐  │                │  ┌───────────┐  │
│  │  Files    │  │                │  │  Files    │  │
│  │  Inodes   │  │    Transfer    │  │  Inodes   │  │
│  │  Bitmaps  │  │    Journal     │  │  Bitmaps  │  │
│  ├───────────┤  │  ──────────>   │  ├───────────┤  │
│  │  JOURNAL  │  │                │  │  JOURNAL  │──┐
│  │  ▪ Desc   │  │                │  │  ▪ Desc   │  │
│  │  ▪ Data   │  │                │  │  ▪ Data   │  │
│  │  ▪ Commit │  │                │  │  ▪ Commit │  │
│  └───────────┘  │                │  └───────────┘  │
└─────────────────┘                └────────┬────────┘
                                            │
                                      Journal Replay
                                            │
                                            ▼
                                   ┌─────────────────┐
                                   │ Updated Files!  │
                                   └─────────────────┘
```

## Components

### 1. `journal_replicate_capture.sh`
Captures journal state from source filesystem.

**What it captures:**
- Filesystem superblock (block size, inode size, etc.)
- Journal superblock (sequence number, start position)
- All journal transaction blocks
- Journal inode information (where journal lives on disk)

**Output:**
- `00_filesystem_superblock.txt` - Full filesystem metadata
- `01_journal_superblock.txt` - Journal configuration
- `02_journal_dump.txt` - Transaction details
- `03_journal_inode.txt` - Journal block locations
- `04_journal_blocks.raw` - Raw journal block data
- `replication_metadata.txt` - Machine-readable metadata

### 2. `journal_replicate_inject.sh`
Injects captured journal into replica filesystem.

**What it does:**
- Validates replica is compatible (same block/inode size)
- Locates journal on replica filesystem
- Writes journal blocks to exact same location
- Marks filesystem as needing recovery
- Creates backup before modification

### 3. `journal_replicate_demo.sh`
End-to-end demonstration showing the complete workflow.

## Usage

### Quick Demo

```bash
# Run the full demonstration
chmod +x journal_replicate_demo.sh
sudo ./journal_replicate_demo.sh
```

This creates two filesystems, makes changes on one, and replicates to the other.

### Manual Workflow

#### Step 1: Create Base Filesystem (Both Servers)

```bash
# Server1: Create base filesystem
dd if=/dev/zero of=fs.img bs=1M count=100
./misc/mke2fs -t ext4 -F fs.img

# Transfer to Server2
scp fs.img server2:/path/to/fs.img
```

**CRITICAL:** Both servers must start with **identical** filesystems. Use `scp` or `rsync` to ensure byte-for-byte copies.

#### Step 2: Make Changes on Server1

```bash
# Mount with data=journal mode (journals all data)
LOOP=$(losetup -f)
losetup $LOOP fs.img
mount -o data=journal,barrier=0,commit=9999 $LOOP /mnt

# Make changes
echo "hello" > /mnt/abc.txt
mkdir /mnt/mydir
echo "test" > /mnt/mydir/file.txt

# Wait for journal commit, then FREEZE to prevent checkpoint
sleep 2  # Wait for ext4 to commit to journal
fsfreeze -f /mnt  # Freeze to prevent checkpoint
```

#### Step 3: Capture Journal State

```bash
# Server1: Capture journal (while frozen!)
# Freeze prevents checkpoint, keeping transactions in journal
./journal_replicate_capture.sh fs.img capture_output/

# Unfreeze and unmount
fsfreeze -u /mnt
umount /mnt
losetup -d $LOOP

# Transfer to Server2
tar czf capture.tar.gz capture_output/
scp capture.tar.gz server2:/path/to/
```

#### Step 4: Inject on Server2

```bash
# Server2: Extract and inject
tar xzf capture.tar.gz
./journal_replicate_inject.sh fs.img capture_output/
```

#### Step 5: Replay Journal

```bash
# Server2: Trigger journal replay
./e2fsck/e2fsck -fy fs.img

# Mount and verify
mount fs.img /mnt
ls -la /mnt
# Should see abc.txt and mydir/
```

## How It Works

### Journal Structure

An ext4 journal contains:

1. **Journal Superblock** - Metadata about journal state
   - `s_sequence` - Current transaction ID
   - `s_start` - First valid transaction block
   - `s_first` - First block of journal
   - `s_maxlen` - Journal size in blocks

2. **Descriptor Blocks** - List what will change
   ```
   Transaction 5, Descriptor Block:
     FS block 1024 -> journal block 10
     FS block 2048 -> journal block 11
     FS block 3072 -> journal block 12
   ```

3. **Data Blocks** - The actual modified data
   - Copies of filesystem blocks being changed
   - Includes metadata (inodes, bitmaps) and file data

4. **Commit Blocks** - Mark transaction complete
   - Contains checksum
   - Atomic commit point

5. **Revoke Blocks** - Cancel previous entries
   - Used for block reuse scenarios

### Replication Process

1. **Capture Phase:**
   ```
   Source FS → Read journal inode → Find journal blocks → Extract to file
   ```

2. **Transfer Phase:**
   ```
   Server1 → scp/network → Server2
   ```

3. **Injection Phase:**
   ```
   Journal file → Write to replica's journal blocks → Mark for recovery
   ```

4. **Replay Phase:**
   ```
   e2fsck → Read journal → Apply changes → Update filesystem
   ```

### What Gets Replicated

Everything in the journal transaction:
- ✅ File data (in data=journal mode)
- ✅ File metadata (inodes, permissions, timestamps)
- ✅ Directory entries
- ✅ Block/inode bitmaps
- ✅ Superblock changes
- ✅ Extended attributes

## Important Considerations

### Mount Options

**Critical for capturing journal content:**

```bash
mount -o data=journal,barrier=0,commit=9999 device /mnt
```

- **`data=journal`** - Journals ALL data (not just metadata)
  - Default `ordered` mode only journals metadata
  - Required to replicate file contents

- **`barrier=0`** - Disables write barriers
  - Prevents immediate checkpointing
  - Keeps transactions in journal longer

- **`commit=9999`** - Delays auto-commit
  - Default is 5 seconds
  - Gives time to capture journal before checkpoint

### Limitations

1. **Filesystem Must Be Identical**
   - Source and replica must start from same base
   - Block size, inode size, UUID must match
   - Use `dd` or `cp` to create identical copies

2. **Must Use Long Commit Timeout AND Avoid Sync** ⚠️ CRITICAL
   - Mount with `commit=9999` to delay checkpointing
   - **DO NOT call `sync`** - it triggers immediate checkpoint (empties journal!)
   - Let ext4 naturally commit to journal (happens within seconds)
   - Capture BEFORE the commit timeout expires (9999 seconds = ~2.7 hours)
   - Filesystem can remain mounted during capture
   - Calling `sync` will checkpoint all transactions and make journal empty

3. **Not a Full Backup Solution**
   - Only replicates incremental changes
   - Replica must have the base filesystem
   - Similar to MySQL binlog replication

4. **Single-Direction Only**
   - This is master→replica replication
   - Replica should be read-only or you'll have conflicts
   - For multi-master, need conflict resolution

5. **Requires Root Access**
   - Must use loopback devices
   - Must write to raw filesystem images
   - e2fsck requires root

### Performance

**Advantages:**
- Only transfers journal blocks (typically 8MB-128MB)
- Much smaller than full filesystem copy
- Works at block level (language/filesystem agnostic)

**Disadvantages:**
- Requires unmounting or careful timing
- data=journal mode has write overhead
- Need to transfer entire journal (can't delta compress)

## Advanced Usage

### Continuous Replication

For continuous replication, you'd need:

1. **Keep filesystem mounted:**
   ```bash
   mount -o data=journal,commit=30 ...
   ```

2. **Periodic capture script:**
   ```bash
   while true; do
     ./journal_replicate_capture.sh fs.img capture_$(date +%s)/
     # Transfer to server2
     sleep 30
   done
   ```

3. **Incremental injection:**
   - Track last applied sequence number
   - Only apply new transactions
   - Requires modifying inject script

### Monitoring

Check journal state:
```bash
dumpe2fs fs.img | grep -A 20 "^Journal"
```

Key fields to monitor:
- `Journal sequence` - Increments with each transaction
- `Journal start` - 0 means journal is empty (checkpointed)

### Troubleshooting

**Problem: Journal is empty**
```
Journal start: 0
```
**Solution:** Transactions were checkpointed. Remount with longer `commit=` value.

**Problem: e2fsck says no recovery needed**
```
Clean filesystem, no recovery needed
```
**Solution:** Journal wasn't properly marked as needing replay. Check that injection wrote to correct blocks.

**Problem: Block size mismatch**
```
ERROR: Block size mismatch!
```
**Solution:** Source and replica must have identical block sizes. Recreate with same `mkfs` options.

## Comparison with Other Tools

| Tool | Method | Granularity | Real-time | Complexity |
|------|--------|-------------|-----------|------------|
| **rsync** | File transfer | Files | No | Low |
| **DRBD** | Block replication | Blocks | Yes | High |
| **This tool** | Journal replay | Transactions | No | Medium |
| **LVM snapshot** | Copy-on-write | Blocks | Snapshot | Medium |

## Future Enhancements

Potential improvements:

1. **Incremental replication**
   - Track sequence numbers
   - Only apply new transactions
   - Avoid re-transferring entire journal

2. **Network streaming**
   - Direct socket transfer (no intermediate files)
   - Compress journal blocks in transit

3. **Checksum verification**
   - Verify journal block integrity
   - Detect corruption during transfer

4. **Conflict detection**
   - Detect if replica was modified
   - Warn before overwriting

5. **Automatic failover**
   - Promote replica to master
   - Reverse replication direction

## References

- [ext4 Journal Design](https://ext4.wiki.kernel.org/index.php/Ext4_Disk_Layout#Journal)
- [JBD2 Documentation](https://www.kernel.org/doc/html/latest/filesystems/ext4/journal.html)
- [e2fsprogs Source Code](https://git.kernel.org/pub/scm/fs/ext2/e2fsprogs.git)

## License

This tool is part of e2fsprogs and follows the same GPL license.

## Contributing

To improve this tool:
1. Test with different filesystem configurations
2. Add support for external journals
3. Implement incremental replication
4. Add network transfer protocol

## Contact

For bugs or questions, please file an issue in the e2fsprogs repository.
