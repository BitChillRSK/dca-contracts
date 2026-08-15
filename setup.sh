#!/bin/bash
# setup.sh - Initializes the project and applies necessary modifications for Rootstock compatibility

echo "🔄 Initializing Git submodules..."
git submodule init
git submodule update

echo "🔧 Applying Solidity version compatibility fixes..."
make patch-deps

echo "🏗️ Building the project..."
forge build

echo "✅ Setup complete! The project is ready for development." 
