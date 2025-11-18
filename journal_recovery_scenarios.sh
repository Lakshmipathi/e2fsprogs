#!/bin/bash
#
# Journal Recovery Scenarios
# Test various crash and recovery scenarios
#
# This script demonstrates different failure modes and how the journal handles them

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

IMG_FILE="/tmp/recovery_test.img"
MOUNT_POINT="/tmp/recovery_mnt"
IMG_SIZE_MB=50
JOURNAL_SIZE=8

cleanup() {
    echo -e "\n${YELLOW}Cleaning up...${NC}"
    umount "$MOUNT_POINT" 2>/dev/null || true
    losetup -d "$LOOP_DEV" 2>/dev/null || true
    rm -rf "$MOUNT_POINT"
    rm -f "$IMG_FILE" "$IMG_FILE.backup"
}

trap cleanup EXIT

print_header() {
    echo -e "${BOLD}${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║        JOURNAL RECOVERY SCENARIOS - CRASH TESTING         ║${NC}"
    echo -e "${BOLD}${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo
}

section() {
    echo -e "\n${BOLD}${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${MAGENTA}  $1${NC}"
    echo -e "${BOLD}${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

wait_user() {
    echo -e "\n${YELLOW}Press ENTER to continue...${NC}"
    read
}

info() {
    echo -e "${BLUE}ℹ ${NC}$1"
}

success() {
    echo -e "${GREEN}✓${NC} $1"
}

error() {
    echo -e "${RED}✗${NC} $1"
}

warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

# Create and setup filesystem
setup_filesystem() {
    section "SETUP: Creating Test Filesystem"

    info "Creating ${IMG_SIZE_MB}MB image..."
    dd if=/dev/zero of="$IMG_FILE" bs=1M count=$IMG_SIZE_MB 2>&1 | grep -v records
    success "Image created"

    info "Creating ext4 filesystem with ${JOURNAL_SIZE}MB journal..."
    ./misc/mke2fs -t ext4 -J size=$JOURNAL_SIZE -F "$IMG_FILE" > /dev/null 2>&1
    success "Filesystem created"

    info "Setting up loop device..."
    LOOP_DEV=$(losetup -f)
    losetup "$LOOP_DEV" "$IMG_FILE"
    success "Loop device: $LOOP_DEV"

    mkdir -p "$MOUNT_POINT"
    mount "$LOOP_DEV" "$MOUNT_POINT"
    success "Mounted at $MOUNT_POINT"

    wait_user
}

# Show journal state
show_journal_state() {
    local title="$1"
    echo -e "${CYAN}═══ $title ═══${NC}"
    ./debugfs/debugfs -R "logdump -s" "$IMG_FILE" 2>/dev/null | grep -E "(Journal starts|sequence|maxlen|start|errno)"
    echo
}

# Scenario 1: Simple crash and recovery
scenario_simple_crash() {
    section "SCENARIO 1: Simple Crash and Recovery"

    echo -e "${BOLD}Description:${NC}"
    echo "Create a file, sync it, then create another file without sync"
    echo "Simulate crash, then recover"
    echo

    info "Creating first file (will be committed)..."
    echo "First file - committed at $(date)" > "$MOUNT_POINT/committed.txt"
    sync
    success "File created and committed"

    info "Creating second file (NOT committed)..."
    echo "Second file - not committed at $(date)" > "$MOUNT_POINT/uncommitted.txt"
    warning "File created but NOT synced (simulated crash)"

    info "Unmounting without sync (crash simulation)..."
    umount "$MOUNT_POINT"
    error "CRASH! - dirty unmount"

    wait_user

    show_journal_state "Journal State After Crash"

    info "Running e2fsck to recover..."
    ./e2fsck/e2fsck -fy "$IMG_FILE" 2>&1 | grep -E "(Playing|Pass|clean)"
    success "Recovery complete"

    wait_user

    show_journal_state "Journal State After Recovery"

    info "Remounting and checking files..."
    mount "$LOOP_DEV" "$MOUNT_POINT"

    echo -e "\n${CYAN}Files after recovery:${NC}"
    ls -lh "$MOUNT_POINT/"
    echo

    if [ -f "$MOUNT_POINT/committed.txt" ]; then
        success "committed.txt recovered"
        cat "$MOUNT_POINT/committed.txt"
    else
        error "committed.txt NOT found"
    fi

    if [ -f "$MOUNT_POINT/uncommitted.txt" ]; then
        warning "uncommitted.txt found (transaction may have committed)"
        cat "$MOUNT_POINT/uncommitted.txt"
    else
        info "uncommitted.txt NOT found (transaction didn't commit)"
    fi

    wait_user
}

# Scenario 2: Multiple transactions
scenario_multiple_transactions() {
    section "SCENARIO 2: Multiple Transactions and Checkpoint"

    echo -e "${BOLD}Description:${NC}"
    echo "Create many files to generate multiple transactions"
    echo "Observe journal checkpoint behavior"
    echo

    info "Creating 10 files with sync after each..."
    for i in {1..10}; do
        echo "Transaction $i data at $(date)" > "$MOUNT_POINT/tx_$i.txt"
        sync
        echo -e "${GREEN}✓${NC} Transaction $i committed"
        sleep 0.5
    done

    wait_user

    umount "$MOUNT_POINT"
    show_journal_state "Journal State After 10 Transactions"

    info "Analyzing transactions in journal..."
    echo
    JOURNAL_OUTPUT=$(./debugfs/debugfs -R "logdump -a" "$IMG_FILE" 2>/dev/null)

    DESCRIPTOR_COUNT=$(echo "$JOURNAL_OUTPUT" | grep -c "Descriptor block" || echo "0")
    COMMIT_COUNT=$(echo "$JOURNAL_OUTPUT" | grep -c "Commit block" || echo "0")

    echo -e "${CYAN}Journal statistics:${NC}"
    echo "  Descriptor blocks: $DESCRIPTOR_COUNT"
    echo "  Commit blocks: $COMMIT_COUNT"
    echo

    info "First few transactions:"
    echo "$JOURNAL_OUTPUT" | head -50

    wait_user
    mount "$LOOP_DEV" "$MOUNT_POINT"
}

# Scenario 3: Deletion and revoke blocks
scenario_deletion_revoke() {
    section "SCENARIO 3: File Deletion and Revoke Blocks"

    echo -e "${BOLD}Description:${NC}"
    echo "Create files, delete them, observe revoke blocks"
    echo "Revoke blocks prevent deleted data from being replayed"
    echo

    info "Creating 5 temporary files..."
    for i in {1..5}; do
        echo "Temporary file $i" > "$MOUNT_POINT/temp_$i.txt"
    done
    sync
    success "Files created and committed"

    ls -lh "$MOUNT_POINT/temp_*.txt"
    wait_user

    info "Deleting 3 files..."
    rm "$MOUNT_POINT/temp_1.txt"
    rm "$MOUNT_POINT/temp_3.txt"
    rm "$MOUNT_POINT/temp_5.txt"
    sync
    success "Files deleted and committed"

    wait_user

    umount "$MOUNT_POINT"
    show_journal_state "Journal After Deletions"

    info "Searching for revoke blocks..."
    echo
    REVOKE_OUTPUT=$(./debugfs/debugfs -R "logdump -a" "$IMG_FILE" 2>/dev/null | grep -i -A 10 "revoke")

    if [ -n "$REVOKE_OUTPUT" ]; then
        success "Found revoke blocks!"
        echo "$REVOKE_OUTPUT"
    else
        warning "No explicit revoke blocks found (may be in descriptor flags)"
    fi

    echo
    info "Examining descriptor block flags for revoked blocks..."
    ./debugfs/debugfs -R "logdump -a" "$IMG_FILE" 2>/dev/null | grep -i "deleted"

    wait_user
    mount "$LOOP_DEV" "$MOUNT_POINT"
}

# Scenario 4: Journal wrap-around
scenario_journal_wraparound() {
    section "SCENARIO 4: Journal Wrap-Around"

    echo -e "${BOLD}Description:${NC}"
    echo "Fill journal with many transactions to observe wrap-around"
    echo "Journal is a circular buffer - old transactions get overwritten"
    echo

    info "Getting initial journal state..."
    umount "$MOUNT_POINT"
    INITIAL_START=$(./debugfs/debugfs -R "logdump -s" "$IMG_FILE" 2>/dev/null | grep "Journal starts" | awk '{print $NF}')
    mount "$LOOP_DEV" "$MOUNT_POINT"

    echo -e "${CYAN}Initial journal start block: $INITIAL_START${NC}"
    wait_user

    info "Creating many transactions to fill journal..."
    for i in {1..50}; do
        echo "Transaction $i at $(date +%s.%N)" > "$MOUNT_POINT/wrap_$i.txt"
        sync
        if [ $((i % 10)) -eq 0 ]; then
            echo -e "${GREEN}✓${NC} Completed $i transactions"
        fi
    done

    success "50 transactions completed"
    wait_user

    umount "$MOUNT_POINT"
    FINAL_START=$(./debugfs/debugfs -R "logdump -s" "$IMG_FILE" 2>/dev/null | grep "Journal starts" | awk '{print $NF}')

    echo -e "${CYAN}Final journal start block: $FINAL_START${NC}"

    if [ "$INITIAL_START" != "$FINAL_START" ]; then
        success "Journal start block changed - checkpointing occurred!"
        echo "  Initial: $INITIAL_START"
        echo "  Final:   $FINAL_START"
    else
        info "Journal start unchanged (journal large enough for all transactions)"
    fi

    show_journal_state "Journal After Wrap-Around Test"

    wait_user
    mount "$LOOP_DEV" "$MOUNT_POINT"
}

# Scenario 5: Partial transaction (incomplete commit)
scenario_partial_transaction() {
    section "SCENARIO 5: Partial Transaction (No Commit Block)"

    echo -e "${BOLD}Description:${NC}"
    echo "Simulate a crash during transaction commit"
    echo "Transaction without commit block should NOT be replayed"
    echo

    info "Creating baseline state..."
    echo "Baseline at $(date)" > "$MOUNT_POINT/baseline.txt"
    sync
    success "Baseline committed"

    # Create backup before partial transaction
    umount "$MOUNT_POINT"
    cp "$IMG_FILE" "$IMG_FILE.backup"
    mount "$LOOP_DEV" "$MOUNT_POINT"

    info "Creating file that will have partial transaction..."
    echo "Partial transaction data" > "$MOUNT_POINT/partial.txt"
    # Immediately kill mount without sync
    warning "Simulating crash during transaction..."

    # Force unmount
    umount -l "$MOUNT_POINT" 2>/dev/null || true
    sync
    error "CRASH during transaction!"

    wait_user

    show_journal_state "Journal After Crash (Partial Transaction)"

    info "Running recovery..."
    ./e2fsck/e2fsck -fy "$IMG_FILE" 2>&1 | grep -E "(Playing|Pass|clean)"
    success "Recovery complete"

    wait_user

    show_journal_state "Journal After Recovery"

    mount "$LOOP_DEV" "$MOUNT_POINT"
    echo -e "\n${CYAN}Files after recovery:${NC}"
    ls -lh "$MOUNT_POINT/"
    echo

    if [ -f "$MOUNT_POINT/baseline.txt" ]; then
        success "baseline.txt present (committed transaction)"
    fi

    if [ -f "$MOUNT_POINT/partial.txt" ]; then
        warning "partial.txt present (transaction completed despite crash)"
        cat "$MOUNT_POINT/partial.txt"
    else
        success "partial.txt NOT present (incomplete transaction correctly ignored)"
    fi

    wait_user
}

# Scenario 6: Journal corruption detection
scenario_corruption_detection() {
    section "SCENARIO 6: Journal Corruption Detection"

    echo -e "${BOLD}Description:${NC}"
    echo "Corrupt journal and see how it's detected"
    echo "Checksums should detect corruption"
    echo

    info "Creating clean state..."
    echo "Clean data" > "$MOUNT_POINT/clean.txt"
    sync
    umount "$MOUNT_POINT"

    # Backup clean state
    cp "$IMG_FILE" "$IMG_FILE.clean"

    show_journal_state "Clean Journal State"
    wait_user

    warning "Corrupting journal superblock..."
    # Corrupt a few bytes in the journal
    # Journal typically starts at block 1 for inline journal
    dd if=/dev/urandom of="$IMG_FILE" bs=1 count=16 seek=4096 conv=notrunc 2>/dev/null
    error "Journal superblock corrupted!"

    wait_user

    info "Attempting to mount corrupted filesystem..."
    if mount "$LOOP_DEV" "$MOUNT_POINT" 2>&1; then
        warning "Mount succeeded (kernel may have repaired)"
        umount "$MOUNT_POINT"
    else
        success "Mount failed (corruption detected)"
    fi

    info "Running e2fsck on corrupted filesystem..."
    ./e2fsck/e2fsck -fy "$IMG_FILE" 2>&1 | head -20

    wait_user

    info "Restoring clean state..."
    cp "$IMG_FILE.clean" "$IMG_FILE"
    success "Clean state restored"

    mount "$LOOP_DEV" "$MOUNT_POINT"
}

# Scenario 7: Fast commit demonstration
scenario_fast_commit() {
    section "SCENARIO 7: Fast Commit Operations"

    echo -e "${BOLD}Description:${NC}"
    echo "Fast commits reduce journal size by logging deltas instead of full blocks"
    echo

    info "Checking fast commit support..."
    umount "$MOUNT_POINT"
    FC_SUPPORT=$(./misc/dumpe2fs -h "$IMG_FILE" 2>/dev/null | grep -i "fast_commit" || echo "")

    if [ -n "$FC_SUPPORT" ]; then
        success "Fast commit supported"
        echo "$FC_SUPPORT"
    else
        info "Fast commit not enabled on this filesystem"
    fi

    mount "$LOOP_DEV" "$MOUNT_POINT"

    info "Creating files to observe commit patterns..."
    for i in {1..5}; do
        echo "Fast commit test $i" > "$MOUNT_POINT/fc_$i.txt"
        sync
    done

    umount "$MOUNT_POINT"

    info "Analyzing journal for fast commit blocks..."
    echo
    ./debugfs/debugfs -R "logdump -a" "$IMG_FILE" 2>/dev/null | grep -i -A 3 "fast\|fc_block"

    wait_user
    mount "$LOOP_DEV" "$MOUNT_POINT"
}

# Main menu
main_menu() {
    while true; do
        print_header
        echo -e "${BOLD}Select a scenario to run:${NC}\n"
        echo "  1. Simple crash and recovery"
        echo "  2. Multiple transactions and checkpoint"
        echo "  3. File deletion and revoke blocks"
        echo "  4. Journal wrap-around"
        echo "  5. Partial transaction (no commit)"
        echo "  6. Journal corruption detection"
        echo "  7. Fast commit demonstration"
        echo "  8. Run all scenarios"
        echo "  9. Exit"
        echo
        read -p "Enter choice [1-9]: " choice

        case $choice in
            1) scenario_simple_crash ;;
            2) scenario_multiple_transactions ;;
            3) scenario_deletion_revoke ;;
            4) scenario_journal_wraparound ;;
            5) scenario_partial_transaction ;;
            6) scenario_corruption_detection ;;
            7) scenario_fast_commit ;;
            8)
                scenario_simple_crash
                scenario_multiple_transactions
                scenario_deletion_revoke
                scenario_journal_wraparound
                scenario_partial_transaction
                scenario_corruption_detection
                scenario_fast_commit
                ;;
            9)
                echo -e "\n${GREEN}Exiting...${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid choice${NC}"
                sleep 1
                ;;
        esac
    done
}

# Entry point
print_header
setup_filesystem
main_menu
