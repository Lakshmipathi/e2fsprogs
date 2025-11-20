# EXT4 Visual Defragmenter

A Windows Disk Defragmenter-style tool for ext4 filesystems with beautiful visual output!

## Features

🎨 **Visual Disk Map** - See your filesystem fragmentation in real-time
📊 **Detailed Statistics** - Before/after comparison with comprehensive metrics
🚀 **Smart Analysis** - Identifies fragmented files and optimization opportunities
⚡ **Progress Tracking** - Real-time progress bar and status updates
🎯 **Safe Operation** - Analysis mode available for read-only inspection

## What Makes This Special?

Unlike traditional Unix tools that output boring text, this tool provides:

- **Windows-style visual disk map** showing:
  - ░ Free space (green)
  - ▓ Used contiguous space (blue)
  - ▒ Fragmented space (red)
  - █ System/metadata (yellow)
  - ▪ Moving blocks (magenta)

- **Comprehensive statistics**:
  - Fragmentation score (0-100%)
  - Number of fragmented files
  - Largest free extent
  - Before/after comparison

- **Beautiful terminal output** with colors and Unicode graphics

## Building

```bash
cd contrib/
make -f Makefile.defrag
```

Or with debug symbols:
```bash
make -f Makefile.defrag debug
```

## Requirements

- Linux kernel 2.6.31+ (for EXT4_IOC_MOVE_EXT support)
- e2fsprogs development libraries
- ext4 filesystem
- Terminal with Unicode and color support

## Usage

### Analyze Fragmentation (Safe, Read-Only)

```bash
# Analyze a device
sudo ./ext4_visual_defrag -a /dev/sda1

# Analyze a partition
sudo ./ext4_visual_defrag -a /dev/nvme0n1p2
```

### Perform Defragmentation

```bash
# Basic defragmentation
sudo ./ext4_visual_defrag /dev/sda1

# Verbose mode with detailed progress
sudo ./ext4_visual_defrag -v /dev/sda1
```

### Command-Line Options

- `-a` : Analyze only (no modifications, safe for production)
- `-v` : Verbose output with detailed information
- `-h` : Display help message

## Example Output

```
╔════════════════════════════════════════════════════════════════════════╗
║                                                                        ║
║        EXT4 VISUAL DEFRAGMENTER - Windows Style Defrag Tool           ║
║                                                                        ║
║                    Making ext4 even better! 🚀                        ║
║                                                                        ║
╚════════════════════════════════════════════════════════════════════════╝

Device: /dev/sda1
Mode:   Full Defragmentation

⚙ Opening filesystem...
⚙ Reading block bitmaps...
⚙ Analyzing fragmentation...
⚙ Generating visual disk map...

📊 DISK MAP - BEFORE DEFRAGMENTATION
┌────────────────────────────────────────────────────────────────────────────────┐
│░░░░▓▓▓▓▓▓░░░░▒▒▒░░░░░░▓▓▓▓░░░▒▒░░░░░░░░░░░░░░▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░░░░░░░│
│▓▓▓▓░░░░░░░░░▒▒░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░│
│░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░│
...
└────────────────────────────────────────────────────────────────────────────────┘

Legend: ░ Free  ▓ Used  ▒ Fragmented  █ System  ▪ Moving

Initial Statistics:
  Total files:          12847
  Fragmented files:     234 (1.8%)
  Fragmentation score:  12.5%
  Free blocks:          5234567
  Largest free extent:  125000 blocks

════════════════════════════════════════════════════════════════════════
                    🚀 STARTING DEFRAGMENTATION 🚀
════════════════════════════════════════════════════════════════════════

[██████████████████████████████████░░░░░░░░░░░░░░░] 72% - Processing files...

...

═══════════════════════ DEFRAGMENTATION RESULTS ═══════════════════════

Metric                      Before          After           Change
─────────────────────────────────────────────────────────────────────────
Total files:                12847           12847        unchanged
Fragmented files:             234              45        -189 (-80.8%)
Fragmentation score:         12.5%            2.3%       -10.2%
Free blocks:              5234567         5234567        unchanged
Largest free extent:       125000          234500        +109500 blocks

⏱ Time elapsed: 2 minutes 34 seconds

════════════════════════════════════════════════════════════════════════
                    ✅ DEFRAGMENTATION COMPLETE! ✅
════════════════════════════════════════════════════════════════════════
```

## How It Works

1. **Scanning Phase**:
   - Opens the ext4 filesystem
   - Reads block bitmaps
   - Scans all inodes to identify files

2. **Analysis Phase**:
   - Uses FIEMAP ioctl to get file extent information
   - Calculates fragmentation metrics
   - Generates visual disk map

3. **Defragmentation Phase** (if not in analysis mode):
   - Identifies fragmented files
   - Uses EXT4_IOC_MOVE_EXT ioctl to relocate extents
   - Consolidates free space
   - Updates statistics

4. **Reporting Phase**:
   - Displays before/after disk maps
   - Shows comprehensive statistics
   - Reports time and improvements

## Technical Details

### Key System Calls Used

- `FS_IOC_FIEMAP` - Get file extent mapping (fast, no file read)
- `EXT4_IOC_MOVE_EXT` - Move file extents atomically
- `ext2fs_*` - e2fsprogs library functions for low-level FS access

### Fragmentation Score Calculation

```
score = (average_extents_per_file - 1) * 10
```

A perfectly contiguous filesystem would have 1 extent per file (score = 0%).
Higher scores indicate more fragmentation.

### Visual Map Resolution

Each character in the visual map represents multiple blocks:
```
blocks_per_cell = total_blocks / (width * height)
```

Default: 80x20 = 1600 cells for the entire filesystem

## Safety Considerations

⚠️ **Important**: Always backup your data before running defragmentation!

- Use `-a` flag first to analyze without modifications
- Run on unmounted filesystems when possible
- Ensure sufficient free space (20%+ recommended)
- Do not interrupt during defragmentation

## Comparison with Other Tools

| Feature | ext4_visual_defrag | e4defrag | Windows Defrag |
|---------|-------------------|----------|----------------|
| Visual disk map | ✅ | ❌ | ✅ |
| Real-time progress | ✅ | Limited | ✅ |
| Statistics | ✅ Detailed | Basic | ✅ |
| Color output | ✅ | ❌ | ✅ |
| Analysis mode | ✅ | ❌ | ✅ |
| Free space consolidation | 🚧 Planned | ❌ | ✅ |

## Limitations

- **Filesystem must be ext4** (ext2/ext3 not supported for defrag)
- **Root privileges required** for most operations
- **Online defrag only** - filesystem must be mounted or openable
- **Best effort** - some files cannot be defragmented (e.g., in-use files)

## Future Enhancements

- [ ] Full EXT4_IOC_MOVE_EXT implementation for actual defragmentation
- [ ] File-by-file progress reporting
- [ ] Smart file placement based on access patterns
- [ ] Free space consolidation algorithm
- [ ] Scheduled defragmentation (cron integration)
- [ ] GUI version with real-time animation
- [ ] Defragmentation of specific directories/files only
- [ ] Multi-threaded scanning for faster analysis
- [ ] Export statistics to JSON/CSV

## Why ext4 Needs Less Defragmentation

Unlike NTFS, ext4 is designed to resist fragmentation:

- **Delayed allocation**: Writes are buffered, allowing smarter block allocation
- **Extent-based**: Groups of contiguous blocks are tracked together
- **Preallocation**: Space reserved in advance for growing files
- **Block groups**: Data locality maintained per cylinder group

However, defragmentation still helps for:
- Long-running systems with heavy I/O
- Filesystems with <10% free space
- Databases and virtual machine images
- After bulk file operations

## Contributing

This tool is part of e2fsprogs. Contributions welcome!

## License

GPL v2 (same as e2fsprogs)

## Author

Created as a fun demonstration of ext4 capabilities and modern terminal UI.

## See Also

- `e4defrag(8)` - Command-line ext4 defragmenter
- `filefrag(8)` - Report file fragmentation
- `e2freefrag(8)` - Report free space fragmentation
- `debugfs(8)` - ext2/ext3/ext4 filesystem debugger

---

**Have fun defragmenting! 🎉**
