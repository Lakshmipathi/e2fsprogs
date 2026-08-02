# Implementation Gap Analysis: T0/T1 vs eBPF Delta Replication

## Executive Summary

This document analyzes the gap between the current T0/T1 e2image comparison implementation and the proposed eBPF-based real-time tracking system. It identifies required changes, migration risks, and implementation priorities.

---

## Current Implementation Review

### Existing Files

```
e2fsprogs/
├── test_e2image_delta_replication.sh     # T0/T1 full test (needs loop devices)
├── test_e2image_delta_simple.sh          # T0/T1 proof-of-concept
├── test_e2image_replication.sh           # Basic e2image replication
├── test_e2image_lvm_replication.sh       # LVM snapshot-based
├── test_e2image_live_replication.sh      # Keep filesystems mounted
├── test_blktrace_replication.sh          # blktrace-based tracking
├── misc/e2image.c                        # e2image tool (existing)
└── misc/e2image.8.in                     # e2image man page
```

### Current Workflow (from test_e2image_delta_simple.sh)

```bash
# Phase 1: Create baseline
e2image -ra server1.img baseline_t0.img

# Phase 2: Make changes
[filesystem modifications occur]

# Phase 3: Capture current state  
e2image -ra server1.img current_t1.img

# Phase 4: Compare block-by-block
for block_num in 0..TOTAL_BLOCKS; do
    dd if=baseline_t0.img of=/tmp/block_t0 bs=BLOCK_SIZE skip=$block_num count=1
    dd if=current_t1.img of=/tmp/block_t1 bs=BLOCK_SIZE skip=$block_num count=1
    if ! cmp -s /tmp/block_t0 /tmp/block_t1; then
        echo $block_num >> changed_blocks.txt
    fi
done

# Phase 5: Replicate only changed blocks
while read block_num; do
    dd if=current_t1.img of=server2.img \
       bs=$BLOCK_SIZE skip=$block_num seek=$block_num count=1 conv=notrunc
done < changed_blocks.txt
```

### Strengths of Current Implementation

✓ **Simple** - No kernel dependencies, pure userspace  
✓ **Works today** - Based on existing e2image functionality  
✓ **Proven** - e2image is mature, well-tested  
✓ **No runtime overhead** - Offline comparison  
✓ **Self-contained** - Just bash + e2fsprogs tools  

### Limitations of Current Implementation

✗ **Storage intensive** - Requires 2x full filesystem size for T0/T1 images  
✗ **CPU intensive** - Block-by-block comparison is slow  
✗ **Batch only** - Cannot track changes continuously  
✗ **Snapshot overhead** - Must capture full images at T0 and T1  
✗ **No real-time** - Can't know what changed until T1 snapshot completes  
✗ **Scale limits** - Comparison time grows with filesystem size  

---

## Proposed eBPF Implementation

### New Components Required

```
e2fsprogs/
├── bpf/                              # NEW: eBPF programs
│   ├── e2delta_tracker.bpf.c        # Core eBPF tracking program
│   ├── e2delta_tracker.h            # Shared kernel/userspace headers
│   ├── vmlinux.h                    # Kernel type definitions
│   └── Makefile                     # BPF compilation (clang, llc)
│
├── lib/e2delta/                     # NEW: Library for eBPF interaction
│   ├── tracker.c                    # Load/unload eBPF, read maps
│   ├── tracker.h                    # Public API
│   ├── bitmap.c                     # Bitmap manipulation
│   ├── bitmap.h
│   ├── replicate.c                  # Replication logic
│   ├── replicate.h
│   └── Makefile
│
├── misc/
│   ├── e2delta.c                    # NEW: CLI tool for tracking
│   ├── e2delta.8.in                 # NEW: Man page
│   ├── e2delta-replicate.c          # NEW: Replication daemon
│   ├── e2delta-replicate.8.in       # NEW: Man page
│   └── e2image.c                    # MODIFIED: Add --use-tracker flag
│
├── tests/
│   ├── test_e2delta_tracking.sh     # NEW: Test eBPF tracking
│   ├── test_e2delta_accuracy.sh     # NEW: Compare vs T0/T1
│   ├── test_e2delta_performance.sh  # NEW: Overhead benchmarks
│   ├── test_e2delta_replication.sh  # NEW: End-to-end replication
│   └── test_e2delta_integration.sh  # NEW: Integration with e2image
│
└── doc/
    └── EBPF_DELTA_REPLICATION_DESIGN.md  # Design document
```

---

## Detailed Gap Analysis

### 1. Build System Changes

#### Current Build System
```makefile
# e2fsprogs uses autoconf/automake
# misc/Makefile.in compiles e2image
e2image: $(E2IMAGE_OBJS)
    $(CC) $(LDFLAGS) -o e2image $(E2IMAGE_OBJS) $(LIBS)
```

#### Required Changes

**New: `bpf/Makefile`**
```makefile
# BPF compilation requires clang + llc
CLANG ?= clang
LLC ?= llc
BPFTOOL ?= bpftool

# Kernel headers
KERNEL_VERSION := $(shell uname -r)
VMLINUX := /sys/kernel/btf/vmlinux

# BPF target
e2delta_tracker.bpf.o: e2delta_tracker.bpf.c
    $(CLANG) -g -O2 -target bpf \
        -D__TARGET_ARCH_x86_64 \
        -I/usr/include/bpf \
        -c e2delta_tracker.bpf.c -o e2delta_tracker.bpf.o

# Generate skeleton (for easier userspace loading)
e2delta_tracker.skel.h: e2delta_tracker.bpf.o
    $(BPFTOOL) gen skeleton e2delta_tracker.bpf.o > e2delta_tracker.skel.h
```

**Modified: `configure.ac`**
```bash
# Add checks for BPF dependencies
AC_CHECK_PROG(CLANG, clang, clang, no)
AC_CHECK_PROG(BPFTOOL, bpftool, bpftool, no)
AC_CHECK_HEADER([bpf/libbpf.h], [], [AC_MSG_ERROR([libbpf headers not found])])
AC_CHECK_LIB([bpf], [bpf_object__open], [], [AC_MSG_ERROR([libbpf not found])])

# Optional: make BPF support conditional
AC_ARG_ENABLE([ebpf],
    AS_HELP_STRING([--enable-ebpf], [Enable eBPF delta tracking (requires Linux 5.x+)]),
    [enable_ebpf=$enableval],
    [enable_ebpf=auto])
```

**Modified: `misc/Makefile.in`**
```makefile
# Add e2delta tools
E2DELTA_OBJS = e2delta.o ../lib/e2delta/tracker.o ../lib/e2delta/bitmap.o
E2DELTA_REPLICATE_OBJS = e2delta-replicate.o ../lib/e2delta/replicate.o

e2delta: $(E2DELTA_OBJS)
    $(CC) $(LDFLAGS) -o e2delta $(E2DELTA_OBJS) $(LIBS) -lbpf -lelf -lz

e2delta-replicate: $(E2DELTA_REPLICATE_OBJS)
    $(CC) $(LDFLAGS) -o e2delta-replicate $(E2DELTA_REPLICATE_OBJS) $(LIBS) -lbpf
```

**Dependencies:**
- `libbpf-dev` (>= 0.5)
- `clang` (>= 11.0)
- `llvm` (>= 11.0)
- `linux-headers` (>= 5.8)
- `bpftool`
- `libelf-dev`

---

### 2. eBPF Program Implementation

#### File: `bpf/e2delta_tracker.bpf.c`

**Complexity:** HIGH  
**Lines of Code:** ~500-800  
**Dependencies:** vmlinux.h, bpf/bpf_helpers.h  

**Key Challenges:**

1. **Kernel Version Compatibility**
   ```c
   // Must support kernels 5.8+ (minimum for BPF ring buffer)
   // But prefer 5.15+ LTS for stability
   
   // Different hook points by kernel version:
   // < 5.10: kprobe/submit_bio
   // >= 5.10: fentry/submit_bio (faster)
   ```

2. **Block Device Identification**
   ```c
   // Challenge: Get device major/minor from bio
   // Solution: Use bio->bi_bdev->bd_dev
   
   static __always_inline u64 get_device_id(struct bio *bio) {
       struct block_device *bdev = BPF_CORE_READ(bio, bi_bdev);
       dev_t dev = BPF_CORE_READ(bdev, bd_dev);
       return (u64)dev;
   }
   ```

3. **Memory Constraints**
   ```c
   // BPF programs have strict memory limits
   // Cannot allocate large bitmaps on stack
   // Must use BPF maps
   
   #define MAX_BITMAP_SIZE (128 * 1024 * 1024)  // 128MB max
   
   // For 4TB device: 128MB = 1024M blocks * 4KB = 4TB ✓
   ```

4. **Atomic Operations**
   ```c
   // Multiple CPUs may write to same bitmap concurrently
   // Must use atomic operations
   
   __sync_fetch_and_or(&bitmap[idx], 1ULL << bit);  // Atomic bit set
   ```

**Implementation Phases:**

1. **Phase 1:** Basic kprobe hook + single-device bitmap (1 week)
2. **Phase 2:** Multi-device support + device filtering (1 week)
3. **Phase 3:** Optimization (fentry hook, per-CPU maps) (1 week)
4. **Phase 4:** Testing and debugging (1 week)

---

### 3. Userspace Library Implementation

#### File: `lib/e2delta/tracker.c`

**Complexity:** MEDIUM  
**Lines of Code:** ~800-1200  
**Dependencies:** libbpf  

**Key Functions:**

```c
// Initialize eBPF subsystem
int e2delta_init(void) {
    // 1. Load BPF object from skeleton
    // 2. Attach to kprobe/fentry
    // 3. Initialize maps
    // 4. Return handle
}

// Start tracking a device
int e2delta_track_start(const char *device, u64 block_size) {
    // 1. Get device major/minor
    // 2. Allocate bitmap in BPF map
    // 3. Initialize metadata
    // 4. Register in tracking list
}

// Export changed blocks
int e2delta_export_blocks(const char *device, e2delta_block_list *out) {
    // 1. Read bitmap from BPF map
    // 2. Iterate bits to find set ones
    // 3. Build array of block numbers
    // 4. Return to caller
    
    // Challenge: Efficiently iterate large bitmap
    // Solution: Use u64 word-at-a-time + __builtin_popcountll
}
```

**Implementation Phases:**

1. **Phase 1:** Basic load/attach/detach (1 week)
2. **Phase 2:** Map interaction (read/write) (1 week)
3. **Phase 3:** Device management + error handling (1 week)
4. **Phase 4:** Optimization + testing (1 week)

---

### 4. CLI Tool Implementation

#### File: `misc/e2delta.c`

**Complexity:** MEDIUM  
**Lines of Code:** ~600-800  
**Dependencies:** lib/e2delta  

**Commands to Implement:**

```c
// Command dispatch table
struct command {
    const char *name;
    int (*handler)(int argc, char **argv);
    const char *help;
} commands[] = {
    { "track",      cmd_track,      "Manage change tracking" },
    { "export",     cmd_export,     "Export changed blocks" },
    { "reset",      cmd_reset,      "Reset tracking bitmap" },
    { "stats",      cmd_stats,      "Show tracking statistics" },
    { "list",       cmd_list,       "List tracked devices" },
    { NULL, NULL, NULL }
};

// Subcommands for 'track'
// e2delta track start /dev/sda1
// e2delta track stop /dev/sda1
// e2delta track status /dev/sda1
```

**Implementation Phases:**

1. **Phase 1:** Basic command structure + track start/stop (1 week)
2. **Phase 2:** Export command with formats (1 week)
3. **Phase 3:** Stats, reset, list commands (1 week)
4. **Phase 4:** Error handling + man page (1 week)

---

### 5. e2image Integration

#### File: `misc/e2image.c` (MODIFIED)

**Changes Required:**

```c
// Add new flag
static int use_tracker = 0;

// In main():
case 'T':
    use_tracker = 1;
    break;

// In write_raw_image():
if (use_tracker) {
    // NEW CODE PATH
    e2delta_block_list changed;
    if (e2delta_export_blocks(device, &changed) < 0) {
        fprintf(stderr, "Failed to get changed blocks from tracker\n");
        fprintf(stderr, "Falling back to full copy\n");
        use_tracker = 0;
        goto full_copy;
    }
    
    // Copy only changed blocks
    for (i = 0; i < changed.count; i++) {
        blk64_t block = changed.blocks[i];
        copy_block(fs, fd, block);
    }
    
    e2delta_free_blocks(&changed);
} else {
full_copy:
    // EXISTING CODE PATH
    // Copy all blocks
    for (blk = 0; blk < total_blocks; blk++) {
        copy_block(fs, fd, blk);
    }
}
```

**Testing Required:**

1. **Backward compatibility** - Ensure existing e2image behavior unchanged
2. **Tracker integration** - Verify --use-tracker works correctly
3. **Fallback logic** - Test when tracker unavailable
4. **Performance** - Benchmark tracker mode vs full mode

**Estimated Effort:** 1 week

---

### 6. Replication Daemon

#### File: `misc/e2delta-replicate.c`

**Complexity:** HIGH  
**Lines of Code:** ~1500-2000  
**Dependencies:** lib/e2delta, networking libs  

**Core Loop:**

```c
int main(int argc, char **argv) {
    // Parse config
    struct config cfg = parse_config("/etc/e2delta/replicate.conf");
    
    // Initialize tracker
    e2delta_track_start(cfg.source_device, 4096);
    
    // Main replication loop
    while (running) {
        // Export changed blocks
        e2delta_block_list changed;
        e2delta_export_blocks(cfg.source_device, &changed);
        
        if (changed.count == 0) {
            sleep(cfg.interval);
            continue;
        }
        
        // Read blocks from source
        void *data = read_blocks(cfg.source_device, &changed);
        
        // Compress
        void *compressed = compress_data(data, changed.count * 4096, cfg.compression);
        
        // Send to destination
        int ret = send_blocks(cfg.dest_type, cfg.dest_host, compressed);
        
        if (ret < 0) {
            log_error("Replication failed, retrying...");
            continue;
        }
        
        // Verify (optional)
        if (cfg.verify) {
            verify_replication(cfg.source_device, cfg.dest_device, &changed);
        }
        
        // Reset bitmap
        if (cfg.auto_reset) {
            e2delta_reset(cfg.source_device);
        }
        
        free_data(data, compressed);
        e2delta_free_blocks(&changed);
        
        sleep(cfg.interval);
    }
    
    e2delta_track_stop(cfg.source_device);
    return 0;
}
```

**Components:**

1. **Config parser** - YAML/INI config file
2. **Transport layer** - SSH, NBD, local file
3. **Compression** - zstd, lz4, gzip
4. **Verification** - Checksum validation
5. **Logging** - syslog integration
6. **Signal handling** - Graceful shutdown

**Estimated Effort:** 3-4 weeks

---

## Migration Strategy

### Phase 1: Proof of Concept (Week 1-4)

**Goal:** Validate eBPF approach works

**Deliverables:**
1. Basic eBPF program (track writes, update bitmap)
2. Simple CLI to read bitmap
3. Test script comparing with T0/T1 approach

**Success Criteria:**
- eBPF tracker produces identical results to T0/T1 comparison
- Overhead < 2% CPU
- No kernel panics or crashes

**Code Changes:**
```
NEW FILES:
  bpf/e2delta_tracker.bpf.c         (~500 lines)
  lib/e2delta/tracker.c             (~400 lines)
  misc/e2delta.c                    (~200 lines, minimal CLI)
  tests/test_e2delta_poc.sh         (~100 lines)

MODIFIED FILES:
  configure.ac                      (+20 lines)
  Makefile.in                       (+10 lines)
```

**Risk Level:** MEDIUM  
**Reversibility:** HIGH (can delete all new files)

---

### Phase 2: Full Implementation (Week 5-12)

**Goal:** Complete feature parity with design

**Deliverables:**
1. Full eBPF tracker with multi-device support
2. Complete CLI tool (all commands)
3. e2image integration (--use-tracker flag)
4. Comprehensive test suite

**Code Changes:**
```
NEW FILES:
  All files from Phase 1 (expanded)
  lib/e2delta/bitmap.c              (~300 lines)
  lib/e2delta/replicate.c           (~500 lines)
  tests/test_e2delta_tracking.sh    (~200 lines)
  tests/test_e2delta_accuracy.sh    (~150 lines)
  tests/test_e2delta_performance.sh (~100 lines)

MODIFIED FILES:
  misc/e2image.c                    (+150 lines)
  misc/e2image.8.in                 (+50 lines, docs)
```

**Risk Level:** MEDIUM-HIGH  
**Reversibility:** HIGH (conditional compilation)

---

### Phase 3: Replication Daemon (Week 13-16)

**Goal:** Automated continuous replication

**Deliverables:**
1. e2delta-replicate daemon
2. Configuration file format
3. Multiple transport backends
4. Monitoring and logging

**Code Changes:**
```
NEW FILES:
  misc/e2delta-replicate.c          (~1500 lines)
  misc/e2delta-replicate.8.in       (~200 lines, docs)
  etc/e2delta/replicate.conf        (config template)
  systemd/e2delta-replicate.service (systemd unit)

MODIFIED FILES:
  configure.ac                      (+30 lines, config checks)
  misc/Makefile.in                  (+20 lines)
```

**Risk Level:** LOW (separate daemon)  
**Reversibility:** HIGH (disable daemon)

---

### Phase 4: Production Hardening (Week 17-20)

**Goal:** Production-ready quality

**Deliverables:**
1. Bitmap persistence across reboots
2. Error recovery and retry logic
3. Performance tuning
4. Documentation and examples

**Code Changes:**
```
MODIFIED FILES:
  All existing e2delta files         (cleanup, optimization)
  
NEW FILES:
  doc/e2delta-quickstart.md          (user guide)
  doc/e2delta-troubleshooting.md     (ops guide)
  examples/replicate-db.conf         (example configs)
  examples/replicate-vm.conf
```

**Risk Level:** LOW  
**Reversibility:** N/A (improvements only)

---

## Critical Risks & Mitigation

### Risk 1: Kernel Compatibility

**Problem:** eBPF features vary by kernel version

**Mitigation:**
```c
// Runtime kernel version check
if (kernel_version < KERNEL_VERSION(5, 8, 0)) {
    fprintf(stderr, "Error: Kernel 5.8+ required for eBPF tracking\n");
    fprintf(stderr, "Your kernel: %d.%d.%d\n", ...);
    fprintf(stderr, "Falling back to T0/T1 comparison mode\n");
    return -1;
}

// Use feature detection
if (bpf_probe_helper(BPF_FUNC_ringbuf_reserve) == 0) {
    // Use ring buffer (faster)
} else {
    // Fall back to perf buffer
}
```

### Risk 2: Memory Overhead for Large Devices

**Problem:** 4TB device = 128MB bitmap

**Mitigation:**
```c
// Implement tiered bitmap
// Tier 1: Active blocks (last 1 hour)     - dense bitmap
// Tier 2: Recent blocks (last 24 hours)   - sparse bitmap  
// Tier 3: Old blocks (> 24 hours)         - flush to disk

// Or: Use run-length encoding for sparse changes
struct rle_entry {
    u64 start_block;
    u64 length;
};
```

### Risk 3: Lost Changes on Crash

**Problem:** In-memory bitmap lost on reboot

**Mitigation:**
```c
// Periodic bitmap persistence
void persist_bitmap(const char *device) {
    // Save to /var/lib/e2delta/<device>.bitmap
    // Restore on tracker start
}

// Also: Use BPF map pinning
bpf_obj_pin(map_fd, "/sys/fs/bpf/e2delta_bitmap");
// Survives process restart
```

### Risk 4: False Positives (unnecessary replication)

**Problem:** Metadata writes don't represent user data changes

**Mitigation:**
```c
// Filter journal blocks
if (is_journal_block(bio, fs)) {
    return 0;  // Don't track
}

// Filter known metadata blocks
if (is_metadata_block(block, fs)) {
    // Option 1: Don't track
    // Option 2: Track separately (metadata_bitmap)
}
```

---

## Performance Comparison Matrix

| Metric | Current (T0/T1) | Proposed (eBPF) | Improvement |
|--------|-----------------|-----------------|-------------|
| **Storage overhead** | 2TB (full images) | 32MB (bitmap) | 99.998% reduction |
| **CPU overhead** | 15 min (100% single core) | <1% continuous | 250x reduction |
| **Latency** | Hours (batch) | Seconds (real-time) | 1000x faster |
| **Bandwidth** | 50GB (5% change) | 50GB (5% change) | Same |
| **Setup complexity** | Low | Medium | Acceptable |
| **Runtime impact** | Zero (offline) | <1% | Negligible |

---

## Decision Matrix: Should We Implement eBPF?

### Pros

✓ **Massive storage savings** - No need for T0/T1 full images  
✓ **Real-time tracking** - Know changes immediately  
✓ **Better performance** - No expensive comparison step  
✓ **Continuous operation** - Can replicate on any schedule  
✓ **Lower latency** - Don't wait for snapshot  
✓ **Modern approach** - Aligns with Linux kernel evolution  

### Cons

✗ **Kernel dependency** - Requires Linux 5.8+  
✗ **Implementation complexity** - eBPF is harder than bash  
✗ **New dependencies** - libbpf, clang, llvm  
✗ **Learning curve** - Team needs eBPF knowledge  
✗ **Potential bugs** - New code has new risks  

### Recommendation

**IMPLEMENT IN PHASES**

1. **Keep T0/T1 approach** as the stable, proven method
2. **Implement eBPF** as an optional enhancement (--enable-ebpf)
3. **Run in parallel** for validation period
4. **Gradually migrate** as confidence builds

**Conditional compilation:**
```c
#ifdef HAVE_EBPF
    if (use_tracker) {
        e2delta_track_and_replicate();
    } else {
        traditional_t0_t1_approach();
    }
#else
    traditional_t0_t1_approach();
#endif
```

---

## Implementation Checklist

### Prerequisites
- [ ] Team training on eBPF fundamentals
- [ ] Development environment setup (kernel 5.8+)
- [ ] Install dependencies (libbpf-dev, clang, bpftool)
- [ ] Set up test infrastructure

### Phase 1: PoC (Weeks 1-4)
- [ ] Basic eBPF program compiles
- [ ] eBPF program loads without errors
- [ ] Bitmap updates on writes
- [ ] Userspace can read bitmap
- [ ] Comparison with T0/T1 shows 100% match
- [ ] Performance overhead < 2%

### Phase 2: Full Implementation (Weeks 5-12)
- [ ] Multi-device support
- [ ] Full CLI tool (all commands)
- [ ] e2image integration
- [ ] Comprehensive test suite
- [ ] Documentation updated
- [ ] Man pages written

### Phase 3: Daemon (Weeks 13-16)
- [ ] Replication daemon functional
- [ ] Multiple transport backends
- [ ] Configuration file support
- [ ] Systemd integration
- [ ] Monitoring and logging

### Phase 4: Production (Weeks 17-20)
- [ ] Bitmap persistence
- [ ] Error recovery tested
- [ ] Performance tuning complete
- [ ] User guide written
- [ ] Troubleshooting guide written
- [ ] Code review passed
- [ ] Security audit passed

---

## Testing Strategy

### Unit Tests
```bash
# eBPF program
tests/test_ebpf_bitmap_update.c
tests/test_ebpf_device_filter.c
tests/test_ebpf_atomic_ops.c

# Library
tests/test_tracker_api.c
tests/test_bitmap_operations.c
tests/test_export_blocks.c
```

### Integration Tests
```bash
tests/test_e2delta_tracking.sh      # End-to-end tracking
tests/test_e2delta_accuracy.sh      # Compare with T0/T1
tests/test_e2delta_e2image.sh       # e2image --use-tracker
tests/test_e2delta_replication.sh   # Full replication cycle
```

### Performance Tests
```bash
tests/test_e2delta_overhead.sh      # CPU/memory overhead
tests/test_e2delta_scalability.sh   # Large devices (4TB+)
tests/test_e2delta_concurrent.sh    # Multi-device tracking
```

### Stress Tests
```bash
tests/stress_heavy_writes.sh        # High write workload
tests/stress_long_running.sh        # 24+ hour stability
tests/stress_memory_pressure.sh     # Low memory conditions
```

---

## Rollback Plan

### If eBPF Implementation Fails

1. **Immediate:** Disable eBPF features
   ```bash
   ./configure --disable-ebpf
   make clean && make
   ```

2. **Short-term:** Continue with T0/T1 approach
   - Keep existing test scripts
   - Document lessons learned

3. **Long-term:** Consider alternatives
   - blktrace-based tracking (already implemented)
   - LVM snapshot approach (already implemented)
   - Hybrid: T0/T1 with better caching

---

## Conclusion

The eBPF-based delta replication offers significant advantages over the T0/T1 comparison approach, particularly in storage efficiency, latency, and real-time tracking capabilities. However, it also introduces complexity and dependencies.

**Recommended Path Forward:**

1. ✅ **Implement eBPF as optional feature** (--enable-ebpf)
2. ✅ **Keep T0/T1 as default** until eBPF proven
3. ✅ **Run parallel validation** for 2-4 weeks
4. ✅ **Gradual migration** based on results

This strategy minimizes risk while allowing us to benefit from the eBPF advantages if the implementation succeeds.

---

## Appendix: Quick Reference

### Files to Create (Total: ~20 new files)
```
bpf/e2delta_tracker.bpf.c          (~500 lines)
bpf/e2delta_tracker.h              (~200 lines)
lib/e2delta/tracker.c              (~800 lines)
lib/e2delta/bitmap.c               (~400 lines)
lib/e2delta/replicate.c            (~600 lines)
misc/e2delta.c                     (~800 lines)
misc/e2delta-replicate.c           (~1500 lines)
tests/test_e2delta_*.sh            (~1000 lines total)
doc/e2delta-*.md                   (~2000 lines total)
```

### Files to Modify (Total: ~5 files)
```
configure.ac                       (~50 lines added)
misc/Makefile.in                   (~40 lines added)
misc/e2image.c                     (~150 lines added)
misc/e2image.8.in                  (~50 lines added)
README.md                          (~30 lines added)
```

### Total Estimated Effort
- **Lines of Code:** ~7,000-8,000 LOC
- **Development Time:** 16-20 weeks (4-5 months)
- **Team Size:** 2-3 developers
- **Validation Period:** 4-8 weeks

### Key Milestones
- Week 4: PoC validated
- Week 12: Feature complete
- Week 16: Production ready
- Week 20: Fully deployed
