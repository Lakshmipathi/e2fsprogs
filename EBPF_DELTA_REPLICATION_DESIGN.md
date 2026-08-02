# eBPF-Based Delta Replication Implementation Design

## Executive Summary

This document describes a real-time block-level change tracking system for ext4 filesystem replication using eBPF, with optional ublk and nbd enhancements. This approach improves upon the T0/T1 e2image comparison method by eliminating the need for full filesystem snapshots and providing continuous change tracking.

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Components](#components)
4. [Implementation Phases](#implementation-phases)
5. [API Design](#api-design)
6. [Performance Considerations](#performance-considerations)
7. [Comparison with Current Implementation](#comparison-with-current-implementation)
8. [Migration Path](#migration-path)

---

## Overview

### Current Approach (T0/T1 Comparison)

```
T0: e2image -ra /dev/server1 baseline.img
    [time passes, filesystem changes]
T1: e2image -ra /dev/server1 current.img
    compare_blocks(baseline.img, current.img) → changed_blocks.list
    replicate_delta(changed_blocks.list, server2)
```

**Limitations:**
- Requires full filesystem snapshots at T0 and T1
- Storage overhead (2x full image size)
- Cannot track changes continuously
- Comparison is CPU-intensive
- Batch-oriented, not real-time

### Proposed Approach (eBPF Real-Time Tracking)

```
eBPF program attached to block layer
    ↓ (intercepts all writes)
Bitmap of changed blocks (in-memory)
    ↓ (on-demand export)
Changed blocks list → replicate only these blocks
```

**Advantages:**
- Zero storage overhead (bitmap only)
- Real-time change tracking
- Minimal CPU overhead (eBPF runs in kernel)
- Continuous monitoring
- Immediate replication possible

---

## Architecture

### High-Level Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        User Space                           │
│                                                             │
│  ┌──────────────┐  ┌─────────────┐  ┌──────────────┐      │
│  │ Application  │  │ e2delta CLI │  │ Replication  │      │
│  │   Writes     │  │   Tool      │  │   Daemon     │      │
│  └──────┬───────┘  └──────┬──────┘  └──────┬───────┘      │
│         │                 │                 │              │
└─────────┼─────────────────┼─────────────────┼──────────────┘
          │                 │                 │
          │        ┌────────▼────────┐        │
          │        │  BPF Maps API   │        │
          │        │  (read bitmap)  │        │
          │        └────────┬────────┘        │
          │                 │                 │
┌─────────┼─────────────────┼─────────────────┼──────────────┐
│         │    Kernel Space │                 │              │
│         │                 │                 │              │
│         ▼                 │                 │              │
│  ┌─────────────┐          │                 │              │
│  │ VFS Layer   │          │                 │              │
│  └──────┬──────┘          │                 │              │
│         │                 │                 │              │
│         ▼                 │                 │              │
│  ┌─────────────┐          │                 │              │
│  │ ext4 Driver │          │                 │              │
│  └──────┬──────┘          │                 │              │
│         │                 │                 │              │
│         ▼                 ▼                 │              │
│  ┌──────────────────────────────┐          │              │
│  │   Block Layer (bio_submit)   │◄─────────┘              │
│  │  ┌────────────────────────┐  │  eBPF program attached  │
│  │  │  eBPF Program          │  │                         │
│  │  │  - Track writes        │  │                         │
│  │  │  - Update bitmap       │  │                         │
│  │  │  - Filter metadata     │  │                         │
│  │  └────────────────────────┘  │                         │
│  └──────────────┬───────────────┘                         │
│                 │                                          │
│                 ▼                                          │
│  ┌──────────────────────────────┐                         │
│  │    BPF Maps (shared memory)  │                         │
│  │  ┌────────────────────────┐  │                         │
│  │  │ changed_blocks_bitmap  │  │  Per-device bitmaps    │
│  │  │ Key: device_id         │  │                         │
│  │  │ Value: u64[] bitmap    │  │                         │
│  │  └────────────────────────┘  │                         │
│  │  ┌────────────────────────┐  │                         │
│  │  │ stats_map              │  │  Statistics tracking    │
│  │  │ - total_writes         │  │                         │
│  │  │ - changed_blocks_count │  │                         │
│  │  │ - last_write_time      │  │                         │
│  │  └────────────────────────┘  │                         │
│  └──────────────────────────────┘                         │
│                                                            │
└────────────────────────────────────────────────────────────┘
```

### Data Flow

1. **Write Path**
   ```
   Application → VFS → ext4 → Block Layer → eBPF hook → Device
                                              ↓
                                         Update bitmap
   ```

2. **Replication Path**
   ```
   Replication daemon → Read bitmap → Get changed blocks
                                          ↓
                                    Read blocks from device
                                          ↓
                                    Transfer to remote
                                          ↓
                                    Clear bitmap (optional)
   ```

---

## Components

### 1. eBPF Program (`e2delta_tracker.bpf.c`)

**Purpose:** Intercept block writes and track changed blocks

**Key Functions:**

```c
// eBPF program structure
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __type(key, u64);           // Device ID
    __type(value, struct bitmap_data);
    __uint(max_entries, 64);    // Max 64 devices tracked
} device_bitmaps SEC(".maps");

struct bitmap_data {
    u64 bitmap[MAX_BLOCKS / 64];  // Bitmap array
    u64 total_blocks;
    u64 block_size;
    u64 changed_count;
};

// Hook into block layer
SEC("kprobe/submit_bio")
int track_bio_submit(struct pt_regs *ctx) {
    struct bio *bio = (struct bio *)PT_REGS_PARM1(ctx);
    
    // Filter: only track writes
    if (!bio_op_is_write(bio))
        return 0;
    
    // Get device ID
    u64 dev_id = get_device_id(bio);
    
    // Get block range
    u64 start_block = bio->bi_iter.bi_sector / 8;  // Convert 512b to 4K blocks
    u64 num_blocks = bio->bi_iter.bi_size / 4096;
    
    // Update bitmap
    struct bitmap_data *bmap = bpf_map_lookup_elem(&device_bitmaps, &dev_id);
    if (bmap) {
        for (u64 i = 0; i < num_blocks; i++) {
            u64 block = start_block + i;
            u64 idx = block / 64;
            u64 bit = block % 64;
            
            // Set bit in bitmap
            __sync_fetch_and_or(&bmap->bitmap[idx], 1ULL << bit);
        }
        __sync_fetch_and_add(&bmap->changed_count, num_blocks);
    }
    
    return 0;
}
```

**Features:**
- Tracks writes at 4KB block granularity
- Per-device bitmap tracking
- Atomic bitmap updates (thread-safe)
- Minimal overhead (< 1% CPU)
- Automatic filtering of non-write operations

### 2. Userspace Tools

#### 2.1 `e2delta` CLI Tool

**Purpose:** Manage change tracking and export changed blocks

**Commands:**

```bash
# Start tracking a device
e2delta track start /dev/sda1
  → Attaches eBPF program
  → Initializes bitmap
  → Returns tracker ID

# Get changed blocks
e2delta track export /dev/sda1 --format=list
  → Reads bitmap from BPF map
  → Exports block numbers to stdout/file
  → Options: --format=[list|bitmap|ranges]

# Get statistics
e2delta track stats /dev/sda1
  → Shows total blocks tracked
  → Shows changed blocks count
  → Shows memory usage

# Reset tracking (clear bitmap)
e2delta track reset /dev/sda1
  → Clears all bits in bitmap
  → Resets counters
  → Continues tracking new changes

# Stop tracking
e2delta track stop /dev/sda1
  → Detaches eBPF program
  → Frees bitmap memory
```

#### 2.2 `e2delta-replicate` Daemon

**Purpose:** Continuous replication using eBPF tracking

**Configuration:**
```yaml
# /etc/e2delta/replicate.conf
source:
  device: /dev/sda1
  track_interval: 60s        # Export changed blocks every 60s

destination:
  type: nbd                  # nbd, local, ssh
  host: server2.example.com
  port: 10809
  device: /dev/sdb1

replication:
  mode: incremental          # incremental, snapshot
  compression: zstd          # none, gzip, zstd, lz4
  verify: checksums          # none, checksums, full
  batch_size: 1024           # Blocks per batch
  
tracking:
  auto_reset: true           # Clear bitmap after successful replication
  bitmap_persist: /var/lib/e2delta/bitmap.dat  # Persist across reboots
```

**Workflow:**
```python
while True:
    # Export changed blocks
    changed_blocks = e2delta.track_export(device)
    
    if len(changed_blocks) == 0:
        sleep(interval)
        continue
    
    # Read changed blocks from source
    block_data = read_blocks(device, changed_blocks)
    
    # Compress
    compressed = compress(block_data, method='zstd')
    
    # Transfer to destination
    transfer(compressed, destination)
    
    # Apply to destination
    apply_blocks(destination, compressed)
    
    # Verify
    if config.verify == 'checksums':
        verify_checksums(source, destination, changed_blocks)
    
    # Reset tracking
    if config.auto_reset:
        e2delta.track_reset(device)
    
    sleep(interval)
```

### 3. Integration with e2image

**Enhanced e2image with eBPF support:**

```bash
# New flag: --use-tracker
e2image -ra --use-tracker /dev/sda1 destination.img

# Only replicates blocks that eBPF tracker marked as changed
# Much faster than full e2image
# Requires e2delta tracker to be running
```

**Implementation:**
```c
// In e2image.c
if (use_tracker) {
    // Read changed blocks from eBPF bitmap
    changed_blocks = e2delta_get_changed_blocks(device);
    
    // Only copy changed blocks
    for (block in changed_blocks) {
        copy_block(source, dest, block);
    }
} else {
    // Original e2image behavior
    copy_all_blocks(source, dest);
}
```

---

## Implementation Phases

### Phase 1: Core eBPF Tracker (MVP)
**Goal:** Basic block-level change tracking

**Deliverables:**
1. eBPF program (`e2delta_tracker.bpf.c`)
   - Track writes to block devices
   - Maintain per-device bitmap
   - Export via BPF maps

2. Userspace CLI tool (`e2delta`)
   - `track start/stop/export/reset/stats`
   - Read bitmap from kernel
   - Export changed block list

3. Test suite
   - Verify tracking accuracy
   - Performance benchmarks
   - Multi-device testing

**Estimated Effort:** 2-3 weeks

### Phase 2: Replication Integration
**Goal:** Integrate with existing e2image tools

**Deliverables:**
1. Modified `e2image` with `--use-tracker` flag
2. Helper functions for reading tracked blocks
3. Integration tests with existing replication scripts

**Estimated Effort:** 1-2 weeks

### Phase 3: Replication Daemon
**Goal:** Automated continuous replication

**Deliverables:**
1. `e2delta-replicate` daemon
2. Configuration file support
3. Multiple transport backends (local, nbd, ssh)
4. Compression and verification

**Estimated Effort:** 2-3 weeks

### Phase 4: Advanced Features (Optional)
**Goal:** Production-ready enhancements

**Deliverables:**
1. ublk integration for custom block device
2. Deduplication of redundant writes
3. Bitmap persistence across reboots
4. Multi-tier replication (primary → secondary → tertiary)
5. Web dashboard for monitoring

**Estimated Effort:** 3-4 weeks

---

## API Design

### Kernel API (eBPF Maps)

```c
// Map: device_bitmaps
// Key: u64 device_id (e.g., makedev(major, minor))
// Value: struct bitmap_data

struct bitmap_data {
    u64 bitmap[131072];      // 8MB bitmap for 4TB device (4KB blocks)
    u64 total_blocks;        // Total blocks in device
    u64 block_size;          // Block size (default 4096)
    u64 changed_count;       // Number of changed blocks
    u64 last_write_ts;       // Timestamp of last write
};

// Map: stats_map
// Key: u64 device_id
// Value: struct stats_data

struct stats_data {
    u64 total_writes;        // Total write operations
    u64 total_bytes;         // Total bytes written
    u64 start_time;          // Tracking start timestamp
};
```

### Userspace API (libbpf)

```c
// Initialize tracker
int e2delta_init(void);
int e2delta_cleanup(void);

// Device tracking
int e2delta_track_start(const char *device, u64 block_size);
int e2delta_track_stop(const char *device);

// Export changed blocks
typedef struct {
    u64 *blocks;           // Array of block numbers
    size_t count;          // Number of changed blocks
} e2delta_block_list;

int e2delta_export_blocks(const char *device, e2delta_block_list *out);
void e2delta_free_blocks(e2delta_block_list *list);

// Reset tracking
int e2delta_reset(const char *device);

// Statistics
typedef struct {
    u64 total_blocks;
    u64 changed_blocks;
    u64 total_writes;
    double change_percentage;
    time_t tracking_since;
} e2delta_stats;

int e2delta_get_stats(const char *device, e2delta_stats *out);
```

### CLI Interface

```bash
# Tracker management
e2delta track start <device> [--block-size=4096]
e2delta track stop <device>
e2delta track list                    # List all tracked devices
e2delta track stats <device>          # Show statistics

# Export changed blocks
e2delta export <device> [options]
  Options:
    --format=list|bitmap|ranges       # Output format
    --output=<file>                   # Output to file
    --reset                           # Reset after export
    
# Bitmap operations
e2delta reset <device>                # Clear bitmap, continue tracking
e2delta save <device> <file>          # Save bitmap to file
e2delta load <device> <file>          # Load bitmap from file

# Replication (integrated mode)
e2delta replicate <source> <dest> [options]
  Options:
    --mode=incremental|full
    --compress=none|gzip|zstd|lz4
    --verify
    --continuous                      # Keep replicating
    --interval=60s
```

---

## Performance Considerations

### Memory Usage

**Bitmap Size Calculation:**
```
For a 1TB device with 4KB blocks:
  Total blocks = 1TB / 4KB = 256M blocks
  Bitmap size = 256M bits / 8 = 32MB
  
For a 4TB device:
  Total blocks = 1TB / 4KB = 1024M blocks
  Bitmap size = 1024M bits / 8 = 128MB
```

**Optimization:**
- Use compressed bitmap for sparse changes
- Implement tiered bitmap (hot/cold blocks)
- Periodic bitmap compaction

### CPU Overhead

**eBPF Hook Overhead:**
- Per-write cost: ~200-500ns (negligible)
- Bitmap update: Atomic OR operation (very fast)
- No context switches (runs in kernel)

**Expected Impact:**
- < 1% CPU overhead on write workloads
- < 0.1% on read-heavy workloads
- Zero impact when not tracking

### I/O Impact

**Read Operations:**
- No impact (eBPF only tracks writes)

**Write Operations:**
- Bitmap update is in-memory only
- No additional disk I/O
- No write amplification

### Network Bandwidth (Replication)

**Example Scenario:**
```
Device: 1TB
Daily change rate: 5% (50GB changed per day)
Block size: 4KB
Replication interval: 1 hour

Per-interval changes:
  50GB / 24 hours = 2.08GB per hour
  Compression (zstd): ~60% → 832MB per hour
  Bandwidth: ~1.85 Mbps average
  
Compare to full replication:
  1TB / hour = 2.22 Gbps (1200x more bandwidth!)
```

---

## Comparison with Current Implementation

### Feature Matrix

| Feature | T0/T1 Comparison | eBPF Tracking |
|---------|------------------|---------------|
| **Tracking Method** | Snapshot comparison | Real-time eBPF hooks |
| **Storage Overhead** | 2x full size | Bitmap only (~0.003%) |
| **CPU Overhead** | High (full comparison) | Minimal (< 1%) |
| **Latency** | Batch (hours) | Real-time (seconds) |
| **Accuracy** | 100% | 100% |
| **Granularity** | 4KB blocks | 4KB blocks |
| **Continuous Tracking** | No | Yes |
| **Bandwidth Savings** | 90-99% vs full | 95-99.9% vs full |
| **Setup Complexity** | Low (just e2image) | Medium (eBPF + tools) |
| **Dependencies** | e2fsprogs only | Linux 5.x+, libbpf |
| **Snapshot Required** | Yes (2 full images) | No |
| **Runtime Impact** | None (offline) | Minimal (<1% CPU) |
| **Bitmap Persistence** | N/A | Optional |
| **Multi-device** | One at a time | Concurrent tracking |

### Performance Comparison

#### Storage Requirements

**T0/T1 Approach:**
```
1TB device:
  - Baseline (T0): 1TB
  - Current (T1): 1TB
  - Total: 2TB storage needed
```

**eBPF Approach:**
```
1TB device:
  - Bitmap: 32MB
  - Total: 32MB storage needed
  
Savings: 99.997%
```

#### Replication Time

**Scenario:** 1TB device, 5% daily change rate (50GB)

**T0/T1 Approach:**
```
1. Capture T0: ~10 minutes (100MB/s)
2. Wait for changes...
3. Capture T1: ~10 minutes
4. Compare: ~15 minutes (CPU-intensive)
5. Replicate changed blocks: ~5 minutes

Total: ~40 minutes + waiting time
```

**eBPF Approach:**
```
1. Start tracking: <1 second
2. Changes accumulate in real-time...
3. Export bitmap: <1 second
4. Replicate changed blocks: ~5 minutes

Total: ~5 minutes (no snapshots needed)
```

#### CPU Usage

**T0/T1 Comparison:**
- Snapshot capture: Low CPU
- Block comparison: High CPU (100% single core for 15+ min)
- Total CPU-hours: ~0.25

**eBPF Tracking:**
- Real-time tracking: <1% CPU overhead
- Bitmap export: Negligible
- Total CPU-hours: ~0.001

**CPU savings: 250x reduction**

---

## Migration Path

### Step 1: Parallel Implementation (Safe)

```bash
# Continue using current T0/T1 approach
e2image -ra /dev/sda1 baseline.img
[changes occur]
e2image -ra /dev/sda1 current.img
compare_blocks baseline.img current.img > t0t1_changes.list

# ALSO run eBPF tracker
e2delta track start /dev/sda1
[same changes occur]
e2delta export /dev/sda1 > ebpf_changes.list

# Compare results
diff <(sort t0t1_changes.list) <(sort ebpf_changes.list)
# Should be identical!
```

### Step 2: Validation Period (2-4 weeks)

- Run both systems in parallel
- Verify eBPF accuracy matches T0/T1
- Monitor performance impact
- Collect statistics

### Step 3: Gradual Migration

```bash
# Week 1-2: Non-critical systems
# Week 3-4: Development environments
# Week 5-6: Staging systems
# Week 7+: Production (if validated)
```

### Step 4: Full Cutover

- Disable T0/T1 snapshot scripts
- Enable eBPF tracking by default
- Configure continuous replication daemon
- Monitor and optimize

### Rollback Plan

```bash
# If issues arise, immediately:
e2delta track stop /dev/sda1       # Stop eBPF
# Resume T0/T1 approach
e2image -ra /dev/sda1 baseline.img
```

---

## Security Considerations

### eBPF Verification

- eBPF programs verified by kernel verifier
- Cannot crash kernel
- Cannot access unauthorized memory
- Bounded loops (no infinite loops)

### Permissions

```bash
# Requires CAP_BPF or CAP_SYS_ADMIN
# Recommended: create e2delta group
groupadd e2delta
usermod -a -G e2delta replication-user

# Set capabilities on binary
setcap cap_bpf,cap_perfmon+ep /usr/bin/e2delta
```

### Data Protection

- Bitmap contains no user data (only block numbers)
- No risk of data leakage via bitmap
- Replication uses standard encryption (SSH/TLS)

---

## Testing Strategy

### Unit Tests

1. **eBPF Program Tests**
   - Verify bitmap updates on writes
   - Test multi-device tracking
   - Validate atomic operations

2. **Userspace API Tests**
   - Test all CLI commands
   - Verify bitmap export accuracy
   - Test error handling

### Integration Tests

1. **Accuracy Tests**
   ```bash
   # Compare eBPF vs T0/T1
   test_accuracy() {
       # Start both methods
       e2delta track start /dev/loop0
       e2image -ra /dev/loop0 t0.img
       
       # Make known changes
       write_test_pattern /dev/loop0
       
       # Capture results
       e2image -ra /dev/loop0 t1.img
       compare_blocks t0.img t1.img > expected.list
       e2delta export /dev/loop0 > actual.list
       
       # Verify match
       diff expected.list actual.list
   }
   ```

2. **Performance Tests**
   ```bash
   # Measure overhead
   test_overhead() {
       # Baseline: write performance without tracking
       fio --name=baseline --rw=write --bs=4k --size=1G
       
       # With tracking
       e2delta track start /dev/loop0
       fio --name=tracked --rw=write --bs=4k --size=1G
       
       # Compare results (should be < 2% difference)
   }
   ```

3. **Replication Tests**
   - Full replication cycle
   - Verify data integrity
   - Test failure scenarios

### Stress Tests

```bash
# High-frequency writes
fio --name=stress --rw=randwrite --bs=4k --numjobs=16 --runtime=3600

# Multi-device concurrent tracking
for dev in /dev/loop{0..7}; do
    e2delta track start $dev &
done

# Long-running stability (24+ hours)
e2delta-replicate --continuous --interval=60s
```

---

## Appendix A: Code Structure

```
e2fsprogs/
├── bpf/
│   ├── e2delta_tracker.bpf.c      # eBPF program source
│   ├── e2delta_tracker.h          # Shared structures
│   └── Makefile                   # BPF compilation
├── lib/
│   └── e2delta/
│       ├── tracker.c              # BPF map interaction
│       ├── bitmap.c               # Bitmap operations
│       └── replicate.c            # Replication logic
├── misc/
│   ├── e2delta.c                  # CLI tool
│   └── e2delta-replicate.c        # Replication daemon
├── tests/
│   ├── test_e2delta_tracking.sh
│   ├── test_e2delta_accuracy.sh
│   ├── test_e2delta_performance.sh
│   └── test_e2delta_replication.sh
└── doc/
    ├── EBPF_DELTA_REPLICATION_DESIGN.md  # This document
    └── e2delta.8.in                       # Man page
```

---

## Appendix B: References

1. **eBPF Documentation**
   - https://ebpf.io/
   - https://www.kernel.org/doc/html/latest/bpf/

2. **Block Layer Tracing**
   - https://www.kernel.org/doc/Documentation/trace/kprobetrace.txt

3. **libbpf**
   - https://github.com/libbpf/libbpf

4. **Similar Projects**
   - dm-writeboost (device mapper change tracking)
   - bcache (block-level caching)
   - dm-era (block change tracking for thin provisioning)

---

## Glossary

- **eBPF**: Extended Berkeley Packet Filter - technology for running sandboxed programs in the Linux kernel
- **BPF Map**: Shared memory data structure between kernel and userspace
- **bio**: Block I/O structure in Linux kernel
- **Bitmap**: Bit array where each bit represents one block's change status
- **ublk**: Userspace block device framework
- **nbd**: Network Block Device protocol
