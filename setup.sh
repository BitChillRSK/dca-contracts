#!/bin/bash
# setup.sh - Initializes the project dependencies and builds it.

echo "🔄 Initializing Git submodules..."
git submodule init
git submodule update

echo "🏗️ Building the project..."
forge build

echo "✅ Setup complete! The project is ready for development." 
