#!/bin/bash
set -e

# Define locations
INSTALL_LOCATION="$HOME/.local/bin"
DATA_DIR="$HOME/.vscode-server"
VSCODE_VERSION="1.106.3"

echo "=== VS Code Server Setup ==="
echo "Starting installation process..."
echo "Architecture: $(uname -m)"
echo "Home directory: $HOME"
echo "Install location: $INSTALL_LOCATION"

# Create necessary directories
mkdir -p "$INSTALL_LOCATION"
mkdir -p "$DATA_DIR/data/Machine"
mkdir -p "$DATA_DIR/extensions"

# Check if VS Code CLI is already installed
if [ ! -e "$INSTALL_LOCATION"/code ]; then
    echo "Installing VS Code CLI..."
    
    # Determine architecture
    if [ "$(uname -m)" = "x86_64" ]; then
        TARGET="cli-linux-x64"
    elif [ "$(uname -m)" = "aarch64" ] || [ "$(uname -m)" = "arm64" ]; then
        TARGET="cli-linux-arm64"
    else
        echo "ERROR: Unsupported architecture: $(uname -m)"
        exit 1
    fi
    
    echo "Selected target: $TARGET"
    DOWNLOAD_URL="https://update.code.visualstudio.com/${VSCODE_VERSION}/${TARGET}/stable"
    echo "Download URL: $DOWNLOAD_URL"
    
    # Download and install VS Code CLI
    echo "Downloading VS Code CLI..."
    if type curl > /dev/null 2>&1; then
        curl -L "$DOWNLOAD_URL" | tar xz -C "$INSTALL_LOCATION"
    elif type wget > /dev/null 2>&1; then
        wget -qO- "$DOWNLOAD_URL" | tar xz -C "$INSTALL_LOCATION"
    else
        echo "ERROR: Installation failed. Please install curl or wget in your container image."
        exit 1
    fi
    
    chmod +x "$INSTALL_LOCATION"/code
    echo "VS Code CLI installed successfully at: $INSTALL_LOCATION/code"
else
    echo "VS Code CLI already installed at: $INSTALL_LOCATION/code"
fi

# Add to PATH if not already there
export PATH="$INSTALL_LOCATION:$PATH"

# Test the VS Code CLI
echo "Testing VS Code CLI..."
if "$INSTALL_LOCATION"/code --version; then
    echo "VS Code CLI is working correctly."
else
    echo "ERROR: VS Code CLI test failed."
    exit 1
fi

# Test HTTPS connectivity
echo ""
echo "Testing HTTPS connectivity..."
if curl -s -o /dev/null -w "%{http_code}" https://marketplace.visualstudio.com/ | grep -q "200"; then
    echo "Marketplace is reachable"
else
    echo "WARNING: Cannot reach VS Code Marketplace"
fi
echo ""

# Function to install extension for VS Code Server
install_extension_for_server() {
    local extension=$1
    local publisher=$(echo "$extension" | cut -d. -f1)
    local name=$(echo "$extension" | cut -d. -f2)
    
    echo "Installing extension: $extension"
    
    # Download VSIX from marketplace
    local temp_dir=$(mktemp -d)
    local vsix_file="$temp_dir/${extension}.vsix"
    local market_url="https://${publisher}.gallery.vsassets.io/_apis/public/gallery/publisher/${publisher}/extension/${name}/latest/assetbyname/Microsoft.VisualStudio.Services.VSIXPackage"
    
    if curl -L -f -o "$vsix_file" "$market_url" 2>/dev/null; then
        # Extract to extensions directory
        local ext_dir="$DATA_DIR/extensions/${publisher}.${name}"
        mkdir -p "$ext_dir"
        
        if unzip -q -o "$vsix_file" -d "$ext_dir" 2>/dev/null; then
            # Move extension folder contents if needed
            if [ -d "$ext_dir/extension" ]; then
                mv "$ext_dir/extension/"* "$ext_dir/" 2>/dev/null || true
                rmdir "$ext_dir/extension" 2>/dev/null || true
            fi
            
            local version=$(jq -r '.version // "unknown"' "$ext_dir/package.json" 2>/dev/null)
            echo "  ✓ Successfully installed $extension v$version"
        else
            echo "  ✗ Failed to extract $extension"
        fi
    else
        echo "  ✗ Failed to download $extension"
    fi
    
    rm -rf "$temp_dir"
    echo ""
}

# Process configuration and install extensions
if [ -f "/server/configuration.json" ]; then
    if type jq > /dev/null 2>&1; then
        echo "Processing configuration..."
        
        # Get list of extensions - including legacy spots for backwards compatibility
        echo "Extracting extension list..."
        extensions=( $(jq -r -M '[
            .mergedConfiguration.customizations?.vscode[]?.extensions[]?,
            .mergedConfiguration.extensions[]?
            ] | unique | .[]
        ' /server/configuration.json 2>/dev/null || echo "") )
        
        # Install extensions using marketplace download
        if [ ${#extensions[@]} -gt 0 ] && [ "${extensions[0]}" != "" ] && [ "${extensions[0]}" != "null" ]; then
            echo "Found ${#extensions[@]} extensions to install"
            echo ""
            
            # Install each extension
            for extension in "${extensions[@]}"; do
                if [ "$extension" != "" ] && [ "$extension" != "null" ]; then
                    install_extension_for_server "$extension" || true
                fi
            done
            
            echo "Extension installation complete."
        else
            echo "No extensions to install."
        fi
        
        # Get VS Code machine settings - including legacy spots for backwards compatibility
        echo "Processing settings..."
        settings="$(jq -M '[
            .mergedConfiguration.customizations?.vscode[]?.settings?,
            .mergedConfiguration.settings?
            ] | add
        ' /server/configuration.json 2>/dev/null || echo "{}")"
        
        # Place settings in right spot
        if [ "${settings}" != "" ] && [ "${settings}" != "null" ] && [ "${settings}" != "{}" ]; then
            echo "Writing settings to: $DATA_DIR/data/Machine/settings.json"
            echo "${settings}" > "$DATA_DIR/data/Machine/settings.json"
        else
            echo "No settings to apply."
        fi
    else
        echo "ERROR: jq is not installed. Cannot process configuration."
        exit 1
    fi
else
    echo "No configuration.json found at /server/configuration.json"
fi

# List installed extensions
echo ""
echo "Installed extensions:"
if [ -d "$DATA_DIR/extensions" ]; then
    extension_count=0
    for ext_dir in "$DATA_DIR/extensions"/*; do
        if [ -d "$ext_dir" ] && [ -f "$ext_dir/package.json" ]; then
            ext_name=$(basename "$ext_dir")
            ext_display_name=$(jq -r '.displayName // .name // "Unknown"' "$ext_dir/package.json" 2>/dev/null)
            ext_version=$(jq -r '.version // "unknown"' "$ext_dir/package.json" 2>/dev/null)
            echo "  - $ext_name ($ext_display_name) v$ext_version"
            extension_count=$((extension_count + 1))
        fi
    done
    echo "Total: $extension_count extensions"
else
    echo "  None"
fi

# Start VS Code Web Server
echo ""
echo "Starting VS Code Server..."
echo "Server will be available at: http://localhost:8000"
echo ""

# Start server in foreground
# Extensions are managed in the default location under --server-data-dir
exec "$INSTALL_LOCATION/code" serve-web \
    --accept-server-license-terms \
    --host 0.0.0.0 \
    --port 8000 \
    --without-connection-token \
    --server-data-dir "$DATA_DIR"