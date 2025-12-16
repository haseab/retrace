#!/bin/bash
# Reset Retrace database (pre-production only!)

set -e

DB_DIR="$HOME/Library/Application Support/Retrace"
DB_PATH="$DB_DIR/retrace.db"

echo "🗑️  Deleting Retrace database..."

if [ -f "$DB_PATH" ]; then
    rm -f "$DB_PATH"
    echo "   ✓ Deleted retrace.db"
fi

if [ -f "$DB_PATH-wal" ]; then
    rm -f "$DB_PATH-wal"
    echo "   ✓ Deleted retrace.db-wal"
fi

if [ -f "$DB_PATH-shm" ]; then
    rm -f "$DB_PATH-shm"
    echo "   ✓ Deleted retrace.db-shm"
fi

echo ""
echo "✅ Database deleted successfully!"
echo ""
echo "Next steps:"
echo "  1. Launch your app to create a fresh database"
echo "  2. The new database will have:"
echo "     - WAL mode enabled ✓"
echo "     - Auto-vacuum INCREMENTAL ✓"
echo "     - Foreign keys enabled ✓"
