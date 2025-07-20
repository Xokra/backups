#!/bin/bash

# Enhanced Cross-Platform System Restore Script with Nerd Fonts
set -euo pipefail

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Platform detection
detect_platform() {
    if [[ -n "${WSL_DISTRO_NAME:-}" ]] || [[ -n "${WSL_INTEROP:-}" ]] || 
       [[ -f /proc/version ]] && grep -qi "microsoft\|wsl" /proc/version 2>/dev/null; then

        echo "wsl"
    elif [[ $(uname) == "Darwin" ]]; then
        echo "mac"
    elif [[ -f /etc/arch-release ]]; then
        echo "arch"
    else
        echo "unknown"
    fi
}

# Get latest Nerd Fonts version from GitHub API
get_latest_nerd_fonts_version() {
    local version
    version=$(curl -s https://api.github.com/repos/ryanoasis/nerd-fonts/releases/latest | grep '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
    [[ -n "$version" ]] && echo "$version" || echo "v3.2.1"

}


# Install Nerd Fonts
install_nerd_fonts() {
    local platform=$1
    local font_name="Meslo"
    local version=$(get_latest_nerd_fonts_version)

    local temp_dir="/tmp/nerd-fonts-$$"
    
    log_info "Installing $font_name Nerd Font ($version)..."

    
    mkdir -p "$temp_dir"
    cd "$temp_dir"
    
    case $platform in
        "wsl")
            # For WSL with Alacritty on Windows, try Windows Fonts directory first
            local windows_fonts_dir="/mnt/c/Windows/Fonts"
            local windows_user_fonts="/mnt/c/Users/$(whoami)/AppData/Local/Microsoft/Windows/Fonts"

            local installed_to_windows=false
            

            if wget -q "https://github.com/ryanoasis/nerd-fonts/releases/download/$version/$font_name.zip"; then
                unzip -q "$font_name.zip" "*.ttf" 2>/dev/null || true
                if ls *.ttf >/dev/null 2>&1; then
                    # Try Windows system fonts directory first (requires admin)
                    if [[ -d "$windows_fonts_dir" ]] && [[ -w "$windows_fonts_dir" ]]; then
                        log_info "Installing fonts to Windows system directory..."
                        for font in *.ttf; do
                            if cp "$font" "$windows_fonts_dir/" 2>/dev/null; then
                                installed_to_windows=true
                            fi
                        done
                    fi
                    
                    # Try Windows user fonts directory (no admin required)
                    if [[ "$installed_to_windows" == false ]] && [[ -d "$(dirname "$windows_user_fonts")" ]]; then
                        mkdir -p "$windows_user_fonts" 2>/dev/null || true
                        if [[ -d "$windows_user_fonts" ]] && [[ -w "$windows_user_fonts" ]]; then
                            log_info "Installing fonts to Windows user directory..."
                            for font in *.ttf; do
                                if cp "$font" "$windows_user_fonts/" 2>/dev/null; then
                                    installed_to_windows=true
                                fi
                            done
                        fi
                    fi
                    
                    # Fallback to Linux local fonts
                    if [[ "$installed_to_windows" == false ]]; then
                        log_warning "Could not access Windows fonts directories, installing locally..."
                        mkdir -p ~/.local/share/fonts
                        cp *.ttf ~/.local/share/fonts/

                        fc-cache -fv >/dev/null 2>&1
                        log_success "Fonts installed locally. Note: Alacritty on Windows may not see these fonts."
                    else
                        log_success "Fonts installed to Windows. Restart Alacritty to use new fonts."
                        log_info "💡 If fonts don't appear, you may need to run Windows as administrator and install manually"

                    fi

                else
                    log_warning "No TTF fonts found in archive"

                fi
            else

                log_error "Failed to download font archive"
            fi
            ;;
        "mac")

            local font_dir="$HOME/Library/Fonts"
            mkdir -p "$font_dir"
            if wget -q "https://github.com/ryanoasis/nerd-fonts/releases/download/$version/$font_name.zip"; then
                unzip -q "$font_name.zip" "*.ttf" 2>/dev/null || true

                if ls *.ttf >/dev/null 2>&1; then

                    cp *.ttf "$font_dir/"

                    log_success "Fonts installed to ~/Library/Fonts"
                else
                    log_warning "No TTF fonts found in archive"
                fi
            else
                log_error "Failed to download font archive"

            fi
            ;;
        "arch")

            mkdir -p ~/.local/share/fonts
            if wget -q "https://github.com/ryanoasis/nerd-fonts/releases/download/$version/$font_name.zip"; then
                unzip -q "$font_name.zip" -d ~/.local/share/fonts/

                fc-cache -fv >/dev/null 2>&1
                log_success "Fonts installed and font cache updated"
            else

                log_error "Failed to download font archive"
            fi
            ;;
    esac
    
    cd - >/dev/null
    rm -rf "$temp_dir"
}

# Configure Zsh as default shell

configure_zsh() {

    local platform=$1

    

    log_info "Configuring Zsh as default shell..."
    

    # Check if zsh is available
    if ! command -v zsh >/dev/null 2>&1; then

        log_warning "Zsh not found, skipping shell configuration"

        return
    fi
    
    local zsh_path=$(which zsh)

    
    # Check if zsh is in /etc/shells

    if ! grep -q "^$zsh_path$" /etc/shells 2>/dev/null; then
        log_info "Adding $zsh_path to /etc/shells..."
        echo "$zsh_path" | sudo tee -a /etc/shells >/dev/null
    fi
    
    # Change default shell if not already zsh
    if [[ "$SHELL" != "$zsh_path" ]]; then
        log_info "Changing default shell to zsh..."

        chsh -s "$zsh_path"
        log_success "Default shell changed to zsh. Please restart your terminal."
    else
        log_success "Zsh is already the default shell"
    fi
}

# Package installation functions
install_package_manager() {
    local platform=$1
    local manager=$2
    
    case "$platform-$manager" in
        "wsl-snap")
            if ! command -v snap >/dev/null 2>&1; then
                log_info "Installing snapd..."
                sudo apt install -y snapd
            fi
            ;;
        "mac-brew")
            if ! command -v brew >/dev/null 2>&1; then
                log_info "Installing Homebrew..."
                /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
                # Add brew to PATH for current session
                eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null || eval "$(/usr/local/bin/brew shellenv)" 2>/dev/null || true

            fi

            ;;
        "mac-mas")
            if ! command -v mas >/dev/null 2>&1; then
                log_info "Installing mas..."
                brew install mas
            fi
            ;;
        "*-cargo")
            if ! command -v cargo >/dev/null 2>&1; then
                if command -v rustup >/dev/null 2>&1; then
                    log_info "Installing rust toolchain..."
                    rustup default stable
                else
                    log_info "Installing rustup..."
                    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
                    source ~/.cargo/env

                fi
            fi
            ;;
        "arch-aur")

            if ! command -v yay >/dev/null 2>&1 && ! command -v paru >/dev/null 2>&1; then
                log_info "Installing yay..."
                sudo pacman -S --noconfirm git base-devel
                cd /tmp

                git clone https://aur.archlinux.org/yay.git

                cd yay && makepkg -si --noconfirm
                cd .. && rm -rf yay
            fi
            ;;

    esac
}


install_packages() {
    local platform=$1
    local manager=$2
    local package_file="config/packages.$manager"
    
    [[ ! -f "$package_file" ]] && return 0
    [[ ! -s "$package_file" ]] && return 0
    
    log_info "Installing $manager packages..."
    install_package_manager "$platform" "$manager"

    
    local failed=0
    while IFS= read -r package; do
        [[ -z "$package" ]] && continue
        
        case $manager in
            "curated") 
                # For curated packages, try platform-specific package manager first
                if [[ "$platform" == "arch" ]]; then
                    sudo pacman -S --noconfirm "$package" 2>/dev/null || {

                        if command -v yay >/dev/null 2>&1; then
                            yay -S --noconfirm "$package" 2>/dev/null || ((failed++))
                        elif command -v paru >/dev/null 2>&1; then
                            paru -S --noconfirm "$package" 2>/dev/null || ((failed++))

                        else
                            ((failed++))

                        fi
                    }
                elif [[ "$platform" == "mac" ]]; then
                    brew install "$package" 2>/dev/null || ((failed++))

                elif [[ "$platform" == "wsl" ]]; then
                    sudo apt install -y "$package" 2>/dev/null || ((failed++))
                fi

                ;;
            "apt") sudo apt install -y "$package" 2>/dev/null || ((failed++)) ;;
            "snap") sudo snap install "$package" 2>/dev/null || ((failed++)) ;;

            "cargo") cargo install "$package" 2>/dev/null || ((failed++)) ;;
            "pip") pip3 install --user "$package" 2>/dev/null || ((failed++)) ;;

            "npm") npm install -g "$package" 2>/dev/null || ((failed++)) ;;
            "flatpak") flatpak install -y flathub "$package" 2>/dev/null || ((failed++)) ;;
            "brew") brew install "$package" 2>/dev/null || ((failed++)) ;;
            "cask") brew install --cask "$package" 2>/dev/null || ((failed++)) ;;

            "mas") mas install "$package" 2>/dev/null || ((failed++)) ;;
            "pacman") sudo pacman -S --noconfirm "$package" 2>/dev/null || ((failed++)) ;;
            "aur") 

                if command -v yay >/dev/null 2>&1; then
                    yay -S --noconfirm "$package" 2>/dev/null || ((failed++))
                elif command -v paru >/dev/null 2>&1; then
                    paru -S --noconfirm "$package" 2>/dev/null || ((failed++))

                fi
                ;;
        esac
    done < "$package_file"
    
    [[ $failed -gt 0 ]] && log_warning "$failed packages failed to install for $manager"
}

update_system() {
    local platform=$1
    
    log_info "Updating system..."
    case $platform in
        "wsl") sudo apt update && sudo apt upgrade -y ;;
        "mac") 
            # Only update brew if it exists, don't install it here
            if command -v brew >/dev/null 2>&1; then
                brew update && brew upgrade
            fi
            ;;
        "arch") sudo pacman -Syu --noconfirm ;;
    esac

}


main() {
    local platform=$(detect_platform)
    [[ "$platform" == "unknown" ]] && { log_error "Unsupported platform!"; exit 1; }
    
    log_info "Restoring system on platform: $platform"
    
    # Show backup info
    [[ -f config/system-info.txt ]] && { log_info "Backup info:"; cat config/system-info.txt; echo; }

    
    # Update system first
    update_system "$platform"

    

    # Install all packages first
    log_info "🚀 Installing packages..."
    local managers=("curated" "apt" "pacman" "brew" "snap" "cargo" "pip" "npm" "cask" "mas" "aur" "flatpak")
    for manager in "${managers[@]}"; do
        install_packages "$platform" "$manager"
    done
    

    # After all packages are installed, do post-install configuration
    log_info "🎨 Configuring fonts and shell..."
    
    # Install Nerd Fonts
    install_nerd_fonts "$platform"
    
    # Configure Zsh (depends on zsh being installed first)
    configure_zsh "$platform"
    
    log_success "System restore completed!"

    log_info "📝 Post-install checklist:"
    echo "  ✅ System updated"
    echo "  ✅ Packages installed"
    echo "  ✅ Nerd Fonts installed"
    echo "  ✅ Zsh configured as default shell"
    echo "  📋 Manual steps needed:"
    echo "     - Restore your dotfiles"
    echo "     - Restart terminal/Alacritty to use new fonts"
    echo "     - In Firefox: Settings > General > Startup > 'Open previous windows and tabs'"
    echo "     - Verify shell with: echo \$SHELL (should show zsh path)"

    

    # WSL-specific notes
    if [[ "$platform" == "wsl" ]]; then
        echo "  💡 WSL Notes:"
        echo "     - If fonts don't appear in Alacritty, try running Windows as administrator"
        echo "     - Alternatively, manually install fonts from downloaded files"
    fi
}


main "$@"
