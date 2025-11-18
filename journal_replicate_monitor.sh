#!/bin/bash
#
# journal_replicate_monitor.sh - Continuous journal monitor for live replication
#
# This script continuously monitors the journal on server1 and captures
# incremental changes for replication to server2. Server1 stays LIVE -
# no I/O blocking, no freezing, continuous operation.
#
# Usage: ./journal_replicate_monitor.sh <source_fs.img> <output_base_dir> [interval]
#

set -e

if [ $# -lt 2 ]; then
    echo "Usage: $0 <source_fs.img> <output_base_dir> [interval_seconds]"
    echo ""
    echo "Continuously monitors journal on source filesystem for replication."
    echo "Captures journal state every <interval> seconds (default: 2)."
    echo ""
    echo "Example:"
    echo "  $0 /dev/sdb1 /replication/captures 2"
    echo ""
    echo "This runs continuously - press Ctrl+C to stop."
    exit 1
fi

SOURCE_IMG="$1"
OUTPUT_BASE="$2"
INTERVAL="${3:-2}"  # Default 2 seconds

if [ ! -e "$SOURCE_IMG" ]; then
    echo "Error: Source image/device '$SOURCE_IMG' not found"
    exit 1
fi

mkdir -p "$OUTPUT_BASE"

echo "==================================================================="
echo "CONTINUOUS JOURNAL MONITOR"
echo "==================================================================="
echo ""
echo "Source:       $SOURCE_IMG"
echo "Output:       $OUTPUT_BASE"
echo "Interval:     ${INTERVAL}s"
echo "Started:      $(date)"
echo ""
echo "Monitoring... (Ctrl+C to stop)"
echo ""

# Track sequence numbers to detect changes
LAST_SEQ=""
CAPTURE_COUNT=0

# Main monitoring loop
while true; do
    TIMESTAMP=$(date +%s)
    CAPTURE_DIR="$OUTPUT_BASE/capture_${TIMESTAMP}"

    # Get current journal sequence
    CURRENT_SEQ=$(./misc/dumpe2fs "$SOURCE_IMG" 2>/dev/null | grep "Journal sequence:" | awk '{print $3}')

    # Only capture if sequence changed (new transactions)
    if [ "$CURRENT_SEQ" != "$LAST_SEQ" ] && [ -n "$CURRENT_SEQ" ]; then
        echo "[$(date '+%H:%M:%S')] Sequence $LAST_SEQ → $CURRENT_SEQ - Capturing..."

        # Capture journal state (quietly)
        mkdir -p "$CAPTURE_DIR"
        ./journal_replicate_capture.sh "$SOURCE_IMG" "$CAPTURE_DIR" > "$CAPTURE_DIR/capture.log" 2>&1

        # Check if we got transactions
        TRANS_COUNT=$(grep "Transactions found:" "$CAPTURE_DIR/capture.log" | awk '{print $3}')

        if [ -n "$TRANS_COUNT" ] && [ "$TRANS_COUNT" -gt 0 ]; then
            echo "  ✓ Captured $TRANS_COUNT transaction(s) to: $CAPTURE_DIR"
            CAPTURE_COUNT=$((CAPTURE_COUNT + 1))

            # Here you would normally transfer to server2
            # Example: rsync -a "$CAPTURE_DIR" server2:/replication/
            #          ssh server2 "./journal_replicate_inject.sh /dev/sdb1 $CAPTURE_DIR"
        else
            echo "  ⚠ No transactions (journal empty/checkpointed)"
            rm -rf "$CAPTURE_DIR"
        fi

        LAST_SEQ="$CURRENT_SEQ"
    else
        # No new transactions
        echo -ne "[$(date '+%H:%M:%S')] Seq: $CURRENT_SEQ - No changes (captures: $CAPTURE_COUNT)\r"
    fi

    sleep "$INTERVAL"
done
