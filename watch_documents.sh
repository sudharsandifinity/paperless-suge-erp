#!/usr/bin/env bash

WATCH_FOLDER="/mnt/test"
DEST_FOLDER="/opt/hlb-sage-erp/consume"

inotifywait -m -r -e create -e moved_to -e close_write --format '%w%f|%e' "$WATCH_FOLDER" |
while IFS='|' read -r NEWFILE EVENT

do
    echo "Detected event: $NEWFILE ($EVENT)" | systemd-cat -t document-watcher

    # Skip directories
    if [ -d "$NEWFILE" ]; then
        echo "Skipping directory event: $NEWFILE" | systemd-cat -t document-watcher
        continue
    fi

    BASENAME=$(basename "$NEWFILE")
    LOCK_FILE="/tmp/.lock_${BASENAME}"
    DEST_PATH="$DEST_FOLDER/$BASENAME"

    # Skip if already copied
    if [ -f "$DEST_PATH" ]; then
        echo "Skipped (already exists): $DEST_PATH" | systemd-cat -t document-watcher
        continue
    fi

    # Skip if already processing
    if [ -f "$LOCK_FILE" ]; then
        echo "Lock exists, skipping duplicate event for: $NEWFILE" | systemd-cat -t document-watcher
        continue
    fi

    # Wait until file is stable
    LAST_SIZE=0
    STABLE_COUNT=0
    while true; do
        CURRENT_SIZE=$(stat --format=%s "$NEWFILE" 2>/dev/null)
        if [[ $? -ne 0 ]]; then
            echo "File disappeared or inaccessible: $NEWFILE" | systemd-cat -t document-watcher
            break
        fi
        if [[ "$CURRENT_SIZE" == "$LAST_SIZE" && "$CURRENT_SIZE" -gt 0 ]]; then
            ((STABLE_COUNT++))
            if [[ $STABLE_COUNT -ge 2 ]]; then
                break
            fi
        else
            STABLE_COUNT=0
        fi
        LAST_SIZE=$CURRENT_SIZE
        sleep 1
    done

    if [[ $STABLE_COUNT -ge 2 ]]; then
        # Create lock now that file is stable
        touch "$LOCK_FILE"

        if [ ! -f "$DEST_PATH" ]; then
            mv "$NEWFILE" "$DEST_PATH"
            echo "Copied: $NEWFILE → $DEST_PATH" | systemd-cat -t document-watcher
        else
            echo "Skipped (already exists): $DEST_PATH" | systemd-cat -t document-watcher
        fi

        # Clean up lock after processing
        rm -f "$LOCK_FILE"
    else
        echo "File not stable or disappeared: $NEWFILE" | systemd-cat -t document-watcher
    fi
done
