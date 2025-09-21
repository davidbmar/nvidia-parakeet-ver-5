#!/bin/bash
#
# RIVA WebSocket Virtual Environment Activation Helper
#

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Activate virtual environment
if [[ -f "$SCRIPT_DIR/venv-riva-ws/bin/activate" ]]; then
    source "$SCRIPT_DIR/venv-riva-ws/bin/activate"

    # Set environment variables
    export RIVA_VENV_ACTIVE=true
    export PYTHONPATH="${PYTHONPATH}:${SCRIPT_DIR}/src"
    export RIVA_PROJECT_ROOT="$SCRIPT_DIR"

    echo "🐍 RIVA WebSocket virtual environment activated"
    echo "📁 Project root: $RIVA_PROJECT_ROOT"
    echo "🐍 Python: $(which python)"
    echo "📦 Pip: $(which pip)"

    # Show RIVA client info if available
    if python -c "import riva" 2>/dev/null; then
        echo "🤖 RIVA client: Available"
    else
        echo "❌ RIVA client: Not available"
    fi

else
    echo "❌ Virtual environment not found: $SCRIPT_DIR/venv-riva-ws"
    exit 1
fi
