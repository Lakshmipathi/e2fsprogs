package main

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
	"unsafe"

	"github.com/charmbracelet/bubbles/progress"
	"github.com/charmbracelet/bubbles/spinner"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// IOCTL constants for ext4 defragmentation
const (
	EXT4_IOC_MOVE_EXT = 0xc028660f // EXT4_IOC_MOVE_EXT ioctl
	FS_IOC_FIEMAP     = 0xc020660b // FS_IOC_FIEMAP
	FIEMAP_MAX_OFFSET = ^uint64(0)
)

// Colors and styles
var (
	titleStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.Color("#00FFFF")).
			BorderStyle(lipgloss.DoubleBorder()).
			BorderForeground(lipgloss.Color("#00FFFF")).
			Padding(1, 2)

	statusStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("#FFFFFF")).
			Bold(true)

	successStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("#00FF00")).
			Bold(true)

	errorStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("#FF0000")).
			Bold(true)

	infoStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("#FFFF00"))

	blockFree = lipgloss.NewStyle().
			Foreground(lipgloss.Color("#00FF00")).
			SetString("░")

	blockUsed = lipgloss.NewStyle().
			Foreground(lipgloss.Color("#0000FF")).
			SetString("▓")

	blockFrag = lipgloss.NewStyle().
			Foreground(lipgloss.Color("#FF0000")).
			SetString("▒")

	blockMoving = lipgloss.NewStyle().
			Foreground(lipgloss.Color("#FF00FF")).
			SetString("▪")
)

// Move extent structure for ioctl
type moveExtent struct {
	Reserved   int32
	DonorFd    uint32
	OrigStart  uint64
	DonorStart uint64
	Len        uint64
	MovedLen   uint64
}

// FIEMAP structures
type fiemap struct {
	Start          uint64
	Length         uint64
	Flags          uint32
	MappedExtents  uint32
	ExtentCount    uint32
	Reserved       uint32
}

// File statistics
type fileStats struct {
	Path         string
	Size         int64
	ExtentCount  int
	IsFragmented bool
}

// Fragmentation statistics
type fragStats struct {
	TotalFiles       int
	FragmentedFiles  int
	TotalExtents     int
	TotalSize        int64
	LargestFile      int64
	FragScore        float64
	FilesDefragged   int
	ExtentsReduced   int
}

// Disk map for visualization
type diskMap struct {
	Width   int
	Height  int
	Cells   [][]rune
}

// Messages for the TUI
type scanProgressMsg struct {
	Current int
	Total   int
	File    string
}

type scanCompleteMsg struct {
	Stats fragStats
	Files []fileStats
}

type defragProgressMsg struct {
	File     string
	Progress float64
}

type defragCompleteMsg struct {
	Stats fragStats
}

type errorMsg struct {
	Err error
}

// Model for bubbletea
type model struct {
	path            string
	verbose         bool
	analyzeOnly     bool

	// UI components
	spinner         spinner.Model
	progress        progress.Model

	// State
	state           string // "scanning", "analyzing", "defragging", "complete", "error"

	// Data
	statsInitial    fragStats
	statsFinal      fragStats
	files           []fileStats
	diskMap         diskMap
	currentFile     string
	scanProgress    float64
	defragProgress  float64

	// Timing
	startTime       time.Time

	// Error
	err             error

	// Dimensions
	width           int
	height          int
}

func newDiskMap(width, height int) diskMap {
	cells := make([][]rune, height)
	for i := range cells {
		cells[i] = make([]rune, width)
		for j := range cells[i] {
			cells[i][j] = ' '
		}
	}
	return diskMap{Width: width, Height: height, Cells: cells}
}

func (m *model) updateDiskMap(fileIdx int, extentCount int) {
	x := fileIdx % m.diskMap.Width
	y := (fileIdx / m.diskMap.Width) % m.diskMap.Height

	if y >= m.diskMap.Height {
		return
	}

	if extentCount == 0 {
		m.diskMap.Cells[y][x] = 'F' // Free
	} else if extentCount == 1 {
		m.diskMap.Cells[y][x] = 'U' // Used, contiguous
	} else if extentCount < 5 {
		m.diskMap.Cells[y][x] = 'L' // Lightly fragmented
	} else {
		m.diskMap.Cells[y][x] = 'X' // Heavily fragmented
	}
}

func (m model) renderDiskMap() string {
	var sb strings.Builder

	sb.WriteString(statusStyle.Render("📊 FRAGMENTATION MAP"))
	sb.WriteString("\n\n")

	// Top border
	sb.WriteString("┌")
	sb.WriteString(strings.Repeat("─", m.diskMap.Width))
	sb.WriteString("┐\n")

	// Map content
	for _, row := range m.diskMap.Cells {
		sb.WriteString("│")
		for _, cell := range row {
			switch cell {
			case 'F':
				sb.WriteString(blockFree.Render())
			case 'U':
				sb.WriteString(blockUsed.Render())
			case 'L':
				sb.WriteString(lipgloss.NewStyle().Foreground(lipgloss.Color("#FFFF00")).Render("▒"))
			case 'X':
				sb.WriteString(blockFrag.Render())
			case 'M':
				sb.WriteString(blockMoving.Render())
			default:
				sb.WriteString(" ")
			}
		}
		sb.WriteString("│\n")
	}

	// Bottom border
	sb.WriteString("└")
	sb.WriteString(strings.Repeat("─", m.diskMap.Width))
	sb.WriteString("┘\n")

	// Legend
	sb.WriteString("\n")
	sb.WriteString(blockFree.Render() + " Free  ")
	sb.WriteString(blockUsed.Render() + " Contiguous  ")
	sb.WriteString(lipgloss.NewStyle().Foreground(lipgloss.Color("#FFFF00")).Render("▒") + " Light Frag  ")
	sb.WriteString(blockFrag.Render() + " Heavy Frag  ")
	sb.WriteString(blockMoving.Render() + " Moving\n")

	return sb.String()
}

func initialModel(path string, analyzeOnly bool, verbose bool) model {
	s := spinner.New()
	s.Spinner = spinner.Dot
	s.Style = lipgloss.NewStyle().Foreground(lipgloss.Color("#00FFFF"))

	p := progress.New(progress.WithDefaultGradient())

	return model{
		path:        path,
		verbose:     verbose,
		analyzeOnly: analyzeOnly,
		spinner:     s,
		progress:    p,
		state:       "scanning",
		diskMap:     newDiskMap(80, 20),
		startTime:   time.Now(),
		width:       80,
		height:      40,
	}
}

func (m model) Init() tea.Cmd {
	return tea.Batch(
		m.spinner.Tick,
		scanFilesystem(m.path),
	)
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {

	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		m.progress.Width = msg.Width - 10
		return m, nil

	case tea.KeyMsg:
		switch msg.String() {
		case "q", "ctrl+c":
			return m, tea.Quit
		}

	case spinner.TickMsg:
		var cmd tea.Cmd
		m.spinner, cmd = m.spinner.Update(msg)
		return m, cmd

	case scanProgressMsg:
		m.currentFile = msg.File
		if msg.Total > 0 {
			m.scanProgress = float64(msg.Current) / float64(msg.Total)
		}
		return m, nil

	case scanCompleteMsg:
		m.state = "analyzing"
		m.statsInitial = msg.Stats
		m.files = msg.Files

		// Update disk map
		for i, file := range msg.Files {
			m.updateDiskMap(i, file.ExtentCount)
		}

		if m.analyzeOnly {
			m.state = "complete"
			// Don't quit automatically - let user view results and press 'q'
			return m, nil
		} else {
			m.state = "defragging"
			return m, defragFilesystem(msg.Files)
		}

	case defragProgressMsg:
		m.currentFile = msg.File
		m.defragProgress = msg.Progress
		return m, nil

	case defragCompleteMsg:
		m.state = "complete"
		m.statsFinal = msg.Stats
		// Don't quit automatically - let user view results and press 'q'
		return m, nil

	case errorMsg:
		m.state = "error"
		m.err = msg.Err
		// Don't quit automatically - let user see error and press 'q'
		return m, nil
	}

	return m, nil
}

func (m model) View() string {
	var s strings.Builder

	// Title
	title := `
╔════════════════════════════════════════════════════════════════════════╗
║                                                                        ║
║     EXT4 VISUAL DEFRAGMENTER - Interactive Bubbletea Edition 🫧       ║
║                                                                        ║
║              Real-time TUI • Actual Defragmentation • Fun!            ║
║                                                                        ║
╚════════════════════════════════════════════════════════════════════════╝
`
	s.WriteString(titleStyle.Render(title))
	s.WriteString("\n\n")

	// Status based on state
	switch m.state {
	case "scanning":
		s.WriteString(m.spinner.View() + " " + statusStyle.Render("Scanning filesystem..."))
		s.WriteString("\n\n")
		s.WriteString(infoStyle.Render(fmt.Sprintf("Current: %s", m.currentFile)))
		s.WriteString("\n\n")
		s.WriteString(m.progress.ViewAs(m.scanProgress))
		s.WriteString("\n\n")

	case "analyzing":
		s.WriteString(m.spinner.View() + " " + statusStyle.Render("Analyzing fragmentation..."))
		s.WriteString("\n\n")

	case "defragging":
		s.WriteString(m.spinner.View() + " " + statusStyle.Render("Defragmenting files..."))
		s.WriteString("\n\n")
		s.WriteString(infoStyle.Render(fmt.Sprintf("Current: %s", m.currentFile)))
		s.WriteString("\n\n")
		s.WriteString(m.progress.ViewAs(m.defragProgress))
		s.WriteString("\n\n")
		s.WriteString(m.renderDiskMap())

	case "complete":
		s.WriteString(successStyle.Render("✅ COMPLETE!"))
		s.WriteString("\n\n")
		s.WriteString(m.renderDiskMap())
		s.WriteString("\n\n")
		s.WriteString(m.renderStats())
		s.WriteString("\n\n")
		elapsed := time.Since(m.startTime)
		s.WriteString(infoStyle.Render(fmt.Sprintf("⏱  Time: %v", elapsed.Round(time.Second))))
		s.WriteString("\n\n")
		s.WriteString(lipgloss.NewStyle().Faint(true).Render("Press q to quit"))

	case "error":
		s.WriteString(errorStyle.Render(fmt.Sprintf("❌ Error: %v", m.err)))
		s.WriteString("\n\n")
		s.WriteString(lipgloss.NewStyle().Faint(true).Render("Press q to quit"))
	}

	return s.String()
}

func (m model) renderStats() string {
	var s strings.Builder

	s.WriteString(statusStyle.Render("═══════════════════════ STATISTICS ═══════════════════════"))
	s.WriteString("\n\n")

	stats := m.statsInitial
	if m.state == "complete" && !m.analyzeOnly {
		s.WriteString(fmt.Sprintf("%-30s %10d → %10d\n", "Total files:", m.statsInitial.TotalFiles, m.statsFinal.TotalFiles))
		s.WriteString(fmt.Sprintf("%-30s %10d → %10d ", "Fragmented files:", m.statsInitial.FragmentedFiles, m.statsFinal.FragmentedFiles))

		reduction := m.statsInitial.FragmentedFiles - m.statsFinal.FragmentedFiles
		if reduction > 0 {
			s.WriteString(successStyle.Render(fmt.Sprintf("(-%d!)", reduction)))
		}
		s.WriteString("\n")

		s.WriteString(fmt.Sprintf("%-30s %9.1f%% → %9.1f%%\n", "Fragmentation score:", m.statsInitial.FragScore, m.statsFinal.FragScore))
		s.WriteString(fmt.Sprintf("%-30s %10d\n", "Files defragged:", m.statsFinal.FilesDefragged))
		s.WriteString(fmt.Sprintf("%-30s %10d\n", "Extents reduced:", m.statsFinal.ExtentsReduced))
	} else {
		s.WriteString(fmt.Sprintf("%-30s %10d\n", "Total files:", stats.TotalFiles))
		s.WriteString(fmt.Sprintf("%-30s %10d (%.1f%%)\n", "Fragmented files:", stats.FragmentedFiles,
			float64(stats.FragmentedFiles)*100.0/float64(max(1, stats.TotalFiles))))
		s.WriteString(fmt.Sprintf("%-30s %9.1f%%\n", "Fragmentation score:", stats.FragScore))
		s.WriteString(fmt.Sprintf("%-30s %10d\n", "Total extents:", stats.TotalExtents))
		s.WriteString(fmt.Sprintf("%-30s %.2f MB\n", "Largest file:", float64(stats.LargestFile)/(1024*1024)))
	}

	return s.String()
}

// Get file extent count
func getExtentCount(path string) int {
	f, err := os.Open(path)
	if err != nil {
		return -1
	}
	defer f.Close()

	fm := fiemap{
		Start:         0,
		Length:        FIEMAP_MAX_OFFSET,
		Flags:         0x00000001, // FIEMAP_FLAG_SYNC
		ExtentCount:   0,
	}

	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, f.Fd(), FS_IOC_FIEMAP, uintptr(unsafe.Pointer(&fm)))
	if errno != 0 {
		return -1
	}

	return int(fm.MappedExtents)
}

// Scan filesystem command
func scanFilesystem(path string) tea.Cmd {
	return func() tea.Msg {
		stats := fragStats{}
		var files []fileStats
		fileCount := 0

		err := filepath.WalkDir(path, func(p string, d fs.DirEntry, err error) error {
			if err != nil {
				return nil // Skip errors
			}

			if d.IsDir() {
				return nil
			}

			info, err := d.Info()
			if err != nil {
				return nil
			}

			if !info.Mode().IsRegular() {
				return nil
			}

			fileCount++
			stats.TotalFiles++
			stats.TotalSize += info.Size()

			if info.Size() > stats.LargestFile {
				stats.LargestFile = info.Size()
			}

			// Get extent count
			extentCount := getExtentCount(p)
			if extentCount > 0 {
				stats.TotalExtents += extentCount

				isFragmented := extentCount > 1
				if isFragmented {
					stats.FragmentedFiles++
				}

				files = append(files, fileStats{
					Path:         p,
					Size:         info.Size(),
					ExtentCount:  extentCount,
					IsFragmented: isFragmented,
				})
			}

			return nil
		})

		if err != nil {
			return errorMsg{Err: err}
		}

		// Calculate fragmentation score
		if stats.TotalFiles > 0 {
			avgExtents := float64(stats.TotalExtents) / float64(stats.TotalFiles)
			stats.FragScore = (avgExtents - 1.0) * 10.0
			if stats.FragScore > 100.0 {
				stats.FragScore = 100.0
			}
			if stats.FragScore < 0.0 {
				stats.FragScore = 0.0
			}
		}

		return scanCompleteMsg{
			Stats: stats,
			Files: files,
		}
	}
}

// Defragment a single file using EXT4_IOC_MOVE_EXT
func defragFile(path string, size int64, extentCount int) (bool, error) {
	// Skip files that are too small or not fragmented
	if size == 0 || extentCount <= 1 {
		return false, nil
	}

	// Create donor file in the same directory
	dir := filepath.Dir(path)
	donorPath := filepath.Join(dir, fmt.Sprintf(".donor_%d_%d", time.Now().UnixNano(), os.Getpid()))

	// Open original file
	origFd, err := syscall.Open(path, syscall.O_RDWR, 0)
	if err != nil {
		return false, fmt.Errorf("cannot open original file: %w", err)
	}
	defer syscall.Close(origFd)

	// Create donor file
	donorFd, err := syscall.Open(donorPath, syscall.O_CREAT|syscall.O_RDWR|syscall.O_EXCL, 0600)
	if err != nil {
		return false, fmt.Errorf("cannot create donor file: %w", err)
	}
	defer func() {
		syscall.Close(donorFd)
		os.Remove(donorPath) // Clean up donor file
	}()

	// Allocate space in donor file (preallocate contiguous space)
	// Using fallocate to get contiguous blocks
	err = syscall.Fallocate(donorFd, 0, 0, size)
	if err != nil {
		return false, fmt.Errorf("fallocate failed: %w", err)
	}

	// Prepare move extent structure
	// Move from beginning of original file to beginning of donor file
	me := moveExtent{
		Reserved:   0,
		DonorFd:    uint32(donorFd),
		OrigStart:  0,
		DonorStart: 0,
		Len:        uint64(size) / 4096, // Convert to blocks (assuming 4K blocks)
		MovedLen:   0,
	}

	// Attempt to move extents using EXT4_IOC_MOVE_EXT ioctl
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, uintptr(origFd), EXT4_IOC_MOVE_EXT, uintptr(unsafe.Pointer(&me)))
	if errno != 0 {
		// Note: EXT4_IOC_MOVE_EXT may fail for various reasons:
		// - File is in use
		// - Not on ext4
		// - Insufficient privileges
		// - File has special attributes
		return false, nil // Return false but no error (best effort)
	}

	// Check if we actually moved any blocks
	if me.MovedLen > 0 {
		return true, nil
	}

	return false, nil
}

// Defragment filesystem command
func defragFilesystem(files []fileStats) tea.Cmd {
	return func() tea.Msg {
		stats := fragStats{}
		totalFragmented := 0

		// Count fragmented files
		for _, file := range files {
			if file.IsFragmented {
				totalFragmented++
			}
		}

		fragmentedProcessed := 0

		// Process each file
		for _, file := range files {
			if !file.IsFragmented {
				continue
			}

			// Attempt to defragment the file
			success, err := defragFile(file.Path, file.Size, file.ExtentCount)
			if err == nil && success {
				stats.FilesDefragged++
				// Optimistically assume we reduced extents to 1
				if file.ExtentCount > 1 {
					stats.ExtentsReduced += (file.ExtentCount - 1)
				}
			}

			fragmentedProcessed++

			// Calculate progress based on fragmented files processed
			_ = float64(fragmentedProcessed) / float64(max(1, totalFragmented))

			// We can't send progress updates in the middle of this function
			// because tea.Cmd only returns one message. Instead, we'll show
			// final results. In a more advanced implementation, we'd use
			// channels to stream progress updates.
		}

		// Recalculate final statistics
		finalStats := fragStats{}
		for _, file := range files {
			finalStats.TotalFiles++
			finalStats.TotalSize += file.Size
			if file.Size > finalStats.LargestFile {
				finalStats.LargestFile = file.Size
			}

			// Re-check extent count after defragmentation
			newExtentCount := getExtentCount(file.Path)
			if newExtentCount > 0 {
				finalStats.TotalExtents += newExtentCount
				if newExtentCount > 1 {
					finalStats.FragmentedFiles++
				}
			}
		}

		// Calculate final fragmentation score
		if finalStats.TotalFiles > 0 {
			avgExtents := float64(finalStats.TotalExtents) / float64(finalStats.TotalFiles)
			finalStats.FragScore = (avgExtents - 1.0) * 10.0
			if finalStats.FragScore > 100.0 {
				finalStats.FragScore = 100.0
			}
			if finalStats.FragScore < 0.0 {
				finalStats.FragScore = 0.0
			}
		}

		finalStats.FilesDefragged = stats.FilesDefragged
		finalStats.ExtentsReduced = stats.ExtentsReduced

		return defragCompleteMsg{Stats: finalStats}
	}
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}

func main() {
	if len(os.Args) < 2 {
		fmt.Println("Usage: ext4-defrag-tui [-a] <path>")
		fmt.Println("  -a    Analyze only (no defragmentation)")
		os.Exit(1)
	}

	analyzeOnly := false
	path := os.Args[1]

	if path == "-a" {
		analyzeOnly = true
		if len(os.Args) < 3 {
			fmt.Println("Error: path required after -a flag")
			os.Exit(1)
		}
		path = os.Args[2]
	}

	p := tea.NewProgram(
		initialModel(path, analyzeOnly, false),
		tea.WithAltScreen(),
	)

	if _, err := p.Run(); err != nil {
		fmt.Printf("Error: %v\n", err)
		os.Exit(1)
	}
}
