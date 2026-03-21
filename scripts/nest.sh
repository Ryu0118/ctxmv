#!/bin/bash

SRCROOT=$(git rev-parse --show-toplevel)

# Check if nest command is available globally or locally
if [ ! -d "$HOME/.nest/bin" ] || [ ! -f "$HOME/.nest/bin/nest" ]; then
    echo "nest command not found globally or locally. Installing..."
    curl -s https://raw.githubusercontent.com/mtj0928/nest/main/Scripts/install.sh | bash

    # Verify installation was successful
    if [ ! -d "$HOME/.nest/bin" ] || [ ! -f "$HOME/.nest/bin/nest" ]; then
        echo "Failed to install nest command. Please install it manually."
        exit 1
    fi
    echo "nest installed successfully!"

    # Bootstrap only if we had to install nest
    "$HOME/.nest/bin/nest" bootstrap "$SRCROOT/nestfile.yaml"
fi

# Execute nest command with all provided arguments
"$HOME/.nest/bin/nest" "$@"
