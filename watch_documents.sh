#!/usr/bin/env bash

WATCH_FOLDER="/mnt/test"
DEST_FOLDER="/opt/hlb-sage-erp/consume"
DB="/opt/hlb-sage-erp/processed_files.db"

# Initialize SQLite DB if not exists
sqlite3 "$DB" <<EOF
CREATE TABLE IF NOT EXISTS files (
    hash TEXT PRIMARY KEY,
    original_path TEXT,
    saved_path TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
EOF

inotifywait -m -r -e create -e moved_to -e close_write --format '%w%f|%e' "$WATCH_FOLDER" |
while IFS='|' read -r NEWFILE EVENT
do
    echo "Detected event: $NEWFILE ($EVENT)" | systemd-cat -t document-watcher

    # Skip directories
    if [ -d "$NEWFILE" ]; then
        echo "Skipping directory event: $NEWFILE" | systemd-cat -t document-watcher
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
            if [[ $STABLE_COUNT -ge 5 ]]; then
                break
            fi
        else
            STABLE_COUNT=0
        fi
        LAST_SIZE=$CURRENT_SIZE
        sleep 1
    done

    # Get relative path from WATCH_FOLDER
    FILENAME=$(basename "$NEWFILE")

    # Generate content hash
    FILE_HASH=$(sha256sum "$NEWFILE" | awk '{print $1}')
    EXT="${FILENAME##*.}"
    BASE="${FILENAME%.*}"
    FILENAME_HASHED="${BASE}_${FILE_HASH:0:12}.${EXT}"
    DEST_PATH="$DEST_FOLDER/$FILENAME_HASHED"

    # Check if this hash is already in the database
    if sqlite3 "$DB" "SELECT 1 FROM files WHERE hash = '$FILE_HASH' LIMIT 1;" | grep -q 1; then
        echo "Skipped (duplicate content): $NEWFILE (hash=$FILE_HASH)" | systemd-cat -t document-watcher
        continue
    fi

    # Ensure destination folder exists
    mkdir -p "$(dirname "$DEST_PATH")"

    # Copy the file
    cp "$NEWFILE" "$DEST_PATH"
    if [ $? -eq 0 ]; then
        echo "Copied: $NEWFILE → $DEST_PATH" | systemd-cat -t document-watcher
        # Record in SQLite
        sqlite3 "$DB" <<EOF
INSERT INTO files (hash, original_path, saved_path)
VALUES ('$FILE_HASH', '$NEWFILE', '$FILENAME_HASHED');
EOF
    else
        echo "Error copying file: $NEWFILE" | systemd-cat -t document-watcher
    fi

done
