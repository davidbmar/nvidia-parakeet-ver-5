#!/bin/bash
# Cleanup duplicate entries in .env file
# This script removes duplicate variable assignments, keeping the last occurrence

set -euo pipefail

ENV_FILE="${1:-/opt/riva/nvidia-parakeet-ver-6/.env}"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "❌ Environment file not found: $ENV_FILE"
    exit 1
fi

echo "🧹 Cleaning up duplicate entries in $ENV_FILE"

# Create backup
BACKUP_FILE="${ENV_FILE}.backup.$(date +%s)"
sudo cp "$ENV_FILE" "$BACKUP_FILE"
echo "✅ Created backup: $BACKUP_FILE"

# Remove duplicates using awk (keeps last occurrence of each variable)
# Preserves comments and blank lines
sudo awk '
/^[[:space:]]*#/ { print; next }        # Keep comments
/^[[:space:]]*$/ { print; next }        # Keep blank lines
/^[A-Z_][A-Z0-9_]*=/ {                  # Variable assignment
    match($0, /^([A-Z_][A-Z0-9_]*)=(.*)/, arr)
    vars[arr[1]] = $0                   # Store in associative array (overwrites duplicates)
    order[++n] = arr[1]                 # Track order
    next
}
{ print }                                # Keep other lines

END {
    # Print variables in order of first appearance
    seen_count = 0
    for (i = 1; i <= n; i++) {
        key = order[i]
        if (key in vars && !seen[key]) {
            print vars[key]
            seen[key] = 1
            seen_count++
        }
    }
}
' "$BACKUP_FILE" | sudo tee "$ENV_FILE" > /dev/null

echo "✅ Cleaned up .env file"

# Show what changed
ORIGINAL_LINES=$(wc -l < "$BACKUP_FILE")
NEW_LINES=$(wc -l < "$ENV_FILE")
REMOVED_LINES=$((ORIGINAL_LINES - NEW_LINES))

echo ""
echo "📊 Summary:"
echo "   Original lines: $ORIGINAL_LINES"
echo "   New lines: $NEW_LINES"
echo "   Removed duplicates: $REMOVED_LINES"

# Show duplicates that were found
echo ""
echo "🔍 Duplicate variables removed:"
sudo grep "^[A-Z_][A-Z0-9_]*=" "$BACKUP_FILE" | cut -d= -f1 | sort | uniq -d
