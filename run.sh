#!/usr/bin/env bash
# REBINCOOP Secure Erase — startup script
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "================================================"
echo "  REBINCOOP Secure Erase — Starting up..."
echo "================================================"

# Check Python
if ! command -v python3 &>/dev/null; then
    echo "[ERROR] python3 not found. Please install Python 3.11+."
    exit 1
fi

PY_VERSION=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
echo "[INFO] Python version: $PY_VERSION"

# Create virtual environment if needed
if [ ! -d "venv" ]; then
    echo "[INFO] Creating virtual environment..."
    python3 -m venv venv
fi

# Activate venv
source venv/bin/activate 2>/dev/null || source venv/Scripts/activate 2>/dev/null

# Install dependencies
echo "[INFO] Installing dependencies..."
pip install --quiet --upgrade pip
pip install --quiet -r requirements.txt

echo ""
echo "[INFO] Starting server at http://127.0.0.1:8420"
echo "[INFO] Open your browser and navigate to http://127.0.0.1:8420"
echo "[INFO] Press Ctrl+C to stop."
echo ""

python3 main.py
