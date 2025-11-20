# EXT4 Visual Defragmenter - Interactive Bubbletea Edition 🫧

A beautiful, interactive TUI version of the ext4 visual defragmenter built with Go and Bubbletea!

## Features

✨ **Interactive Terminal UI** - Beautiful real-time interface with Bubbletea
🎨 **Animated Progress** - Smooth spinners and progress bars
🔥 **Real Defragmentation** - Actually defragments files using EXT4_IOC_MOVE_EXT
📊 **Live Statistics** - Before/after comparison with comprehensive metrics
🗺️  **Visual Disk Map** - Real-time fragmentation visualization
🚀 **Fast & Efficient** - Written in Go for optimal performance

## What Makes This Version Special?

This is not just another CLI tool - it's a **full interactive TUI experience**:

- **Bubbletea Framework**: Elm-inspired architecture for smooth, responsive UI
- **Lipgloss Styling**: Beautiful colors, gradients, and box drawing
- **Real-time Updates**: Watch your filesystem defragment in real-time
- **Actual Defragmentation**: Uses the real EXT4_IOC_MOVE_EXT ioctl (not a simulation!)
- **Safe Operation**: Best-effort defragmentation with graceful error handling

## Building

### Prerequisites

- Go 1.21 or higher
- Linux kernel 2.6.31+ (for EXT4_IOC_MOVE_EXT support)
- ext4 filesystem

### Quick Build

```bash
cd contrib/go-defrag
go build -o ext4-defrag-tui
```

Or use the Makefile:

```bash
make
```

## Usage

### Analyze Fragmentation (Safe, Read-Only)

```bash
# Analyze a directory
sudo ./ext4-defrag-tui -a /home/user/Documents

# Analyze entire partition mount point
sudo ./ext4-defrag-tui -a /home
```

### Perform Defragmentation

```bash
# Defragment a directory
sudo ./ext4-defrag-tui /home/user/Documents

# Defragment with analysis first
sudo ./ext4-defrag-tui /home
```

### Command-Line Options

- `-a` : Analyze only (no modifications, safe for production)

### Controls

- `q` or `Ctrl+C` : Quit the application

## Example Output

```
╔════════════════════════════════════════════════════════════════════════╗
║                                                                        ║
║     EXT4 VISUAL DEFRAGMENTER - Interactive Bubbletea Edition 🫧       ║
║                                                                        ║
║              Real-time TUI • Actual Defragmentation • Fun!            ║
║                                                                        ║
╚════════════════════════════════════════════════════════════════════════╝

● Defragmenting files...

Current: /home/user/Documents/video.mp4

[████████████████████████████████████░░░░░░░░░░░░░░] 72%

📊 FRAGMENTATION MAP

┌────────────────────────────────────────────────────────────────────────────────┐
│░░░░▓▓▓▓▓▓░░░░▒▒▒░░░░░░▓▓▓▓░░░▒▒░░░░░░░░░░░░░░▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░░░░░░░│
│▓▓▓▓░░░░░░░░░▒▒░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░│
│░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░│
...
└────────────────────────────────────────────────────────────────────────────────┘

Legend: ░ Free  ▓ Contiguous  ▒ Light Frag  ▒ Heavy Frag  ▪ Moving
```

## How It Works

1. **Scanning Phase**:
   - Walks the directory tree recursively
   - Uses FIEMAP ioctl to get extent information for each file
   - Updates progress bar in real-time

2. **Analysis Phase**:
   - Calculates fragmentation metrics
   - Generates visual disk map
   - Identifies fragmented files

3. **Defragmentation Phase** (if not in analysis mode):
   - For each fragmented file:
     - Creates a donor file in the same directory
     - Uses `fallocate()` to preallocate contiguous space
     - Uses `EXT4_IOC_MOVE_EXT` ioctl to move file extents
     - Removes the donor file
   - Updates statistics in real-time

4. **Results Phase**:
   - Shows before/after disk maps
   - Displays comprehensive statistics
   - Reports improvements

## Technical Details

### Key System Calls

- `FS_IOC_FIEMAP` (0xc020660b) - Get file extent mapping
- `EXT4_IOC_MOVE_EXT` (0xc028660f) - Move file extents atomically
- `fallocate()` - Preallocate contiguous space

### Defragmentation Algorithm

```go
1. For each fragmented file:
   a. Open original file with O_RDWR
   b. Create donor file with O_CREAT|O_RDWR|O_EXCL
   c. Fallocate donor file to same size (gets contiguous blocks)
   d. Use EXT4_IOC_MOVE_EXT to swap extents
   e. Close and remove donor file
```

### Bubbletea Architecture

This tool uses the Elm architecture:

- **Model**: Holds all application state (stats, progress, disk map)
- **Update**: Processes messages and updates state
- **View**: Renders the current state to the terminal

Messages flow asynchronously:
- `scanProgressMsg` - Scanning progress updates
- `scanCompleteMsg` - Scanning finished
- `defragProgressMsg` - Defragmentation progress
- `defragCompleteMsg` - Defragmentation finished
- `errorMsg` - Error occurred

## Safety Considerations

⚠️ **Important**: This tool requires root privileges and modifies files!

- **Always backup your data** before running defragmentation
- Use `-a` flag first to analyze without modifications
- Best effort: Some files may not be defragmentable (in-use, system files, etc.)
- Requires sufficient free space for donor files
- Do not interrupt during defragmentation (use Ctrl+C safely)

## Comparison with C Version

| Feature | Go Bubbletea | C Standalone |
|---------|-------------|--------------|
| Interactive TUI | ✅ | ❌ |
| Real-time updates | ✅ | Limited |
| Animated UI | ✅ | ❌ |
| Actual defrag | ✅ | Planned |
| Progress tracking | ✅ Smooth | ✅ Basic |
| Error handling | ✅ Graceful | ✅ Basic |
| Dependencies | Go + libs | None |

## Limitations

- **Root privileges required** for defragmentation
- **ext4 filesystem only** - EXT4_IOC_MOVE_EXT is ext4-specific
- **Best effort** - Some files cannot be defragmented:
  - Files currently in use
  - Files with special attributes (immutable, etc.)
  - Files without write permission
  - System files
- **Block size assumed 4KB** - Works for most systems, but may need adjustment

## Future Enhancements

- [ ] Real-time streaming progress updates (requires channels + goroutines)
- [ ] File-by-file selection (interactive mode)
- [ ] Configurable block size detection
- [ ] Smart file prioritization (defrag large files first)
- [ ] Dry-run mode with predictions
- [ ] Export statistics to JSON
- [ ] Animation of blocks moving in disk map
- [ ] Keyboard navigation (vim-style hjkl)

## Dependencies

This tool uses the following excellent Go libraries:

- **Bubbletea**: Terminal UI framework - https://github.com/charmbracelet/bubbletea
- **Lipgloss**: Style and layout library - https://github.com/charmbracelet/lipgloss
- **Bubbles**: TUI components - https://github.com/charmbracelet/bubbles

## Contributing

This is part of e2fsprogs. Contributions welcome!

## License

GPL v2 (same as e2fsprogs)

## Why Go + Bubbletea?

Go provides:
- **Fast compilation** - Build in seconds
- **Static binary** - No runtime dependencies
- **Easy concurrency** - Goroutines for async operations
- **Great syscall support** - Direct access to Linux ioctls
- **Memory safety** - No segfaults!

Bubbletea provides:
- **Modern architecture** - Elm-inspired, predictable state management
- **Beautiful rendering** - ANSI colors, Unicode, smooth updates
- **Responsive** - Non-blocking IO, smooth animations
- **Composable** - Easy to add new features

Together, they make building interactive CLI tools **fun**! 🎉

## See Also

- `ext4_visual_defrag` - C standalone version
- `e4defrag(8)` - Command-line ext4 defragmenter
- `filefrag(8)` - Report file fragmentation
- `e2freefrag(8)` - Report free space fragmentation

---

**Have fun defragmenting interactively! 🫧**
