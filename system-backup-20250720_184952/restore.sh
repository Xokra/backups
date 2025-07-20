#!/bin/bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

detect_platform() {
    if [[ -n "${WSL_DISTRO_NAME:-}" ]] || [[ -f /proc/version ]] && grep -qi "microsoft\|wsl" /proc/version 2>/dev/null; then
        echo "wsl"
    elif [[ $(uname) == "Darwin" ]]; then
        echo "mac"
    elif [[ -f /etc/arch-release ]]; then
        echo "arch"
    else
        echo "unknown"

    fi
}

install_nerd_fonts() {
    local platform=$1

    log_info "Installing Meslo Nerd Font..."
    
    local version=$(curl -s https://api.github.com/repos/ryanoasis/nerd-fonts/releases/latest 2>/dev/null | grep '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/' 2>/dev/null || echo "v3.2.1")
    local temp_dir="/tmp/nerd-fonts-$$"
    local font_installed=false
    
    mkdir -p "$temp_dir" && cd "$temp_dir" || { log_error "Failed to create temp directory"; return 1; }

    
    if wget -q "https://github.com/ryanoasis/nerd-fonts/releases/download/$version/Meslo.zip" 2>/dev/null; then
        case $platform in
            "wsl")
                if unzip -q Meslo.zip "*.ttf" 2>/dev/null && ls *.ttf >/dev/null 2>&1; then
                    for win_dir in "/mnt/c/Windows/Fonts" "/mnt/c/Users/$USER/AppData/Local/Microsoft/Windows/Fonts"; do
                        if [[ -d "$(dirname "$win_dir" 2>/dev/null)" ]]; then
                            mkdir -p "$win_dir" 2>/dev/null || true
                            if cp *.ttf "$win_dir/" 2>/dev/null; then

                                log_success "✅ Fonts installed to Windows: $win_dir"
                                font_installed=true
                                break
                            fi
                        fi
                    done
                    
                    if [[ "$font_installed" != true ]]; then
                        mkdir -p ~/.local/share/fonts 2>/dev/null && cp *.ttf ~/.local/share/fonts/ 2>/dev/null && fc-cache -fv >/dev/null 2>&1 && {
                            log_warning "⚠️ Fonts installed locally. For Windows Alacritty, install manually to Windows fonts."
                            font_installed=true
                        }
                    fi
                fi

                ;;
            "mac")
                if unzip -q Meslo.zip "*.ttf" 2>/dev/null && ls *.ttf >/dev/null 2>&1; then
                    mkdir -p ~/Library/Fonts && cp *.ttf ~/Library/Fonts/ && {
                        log_success "✅ Fonts installed to ~/Library/Fonts"
                        font_installed=true
                    }
                fi
                ;;
            "arch")
                mkdir -p ~/.local/share/fonts 2>/dev/null && unzip -q Meslo.zip -d ~/.local/share/fonts/ 2>/dev/null && fc-cache -fv >/dev/null 2>&1 && {
                    log_success "✅ Fonts installed and font cache updated"
                    font_installed=true
                }
                ;;
        esac
    else
        log_error "❌ Failed to download font archive"
    fi
    
    cd - >/dev/null 2>&1 && rm -rf "$temp_dir" 2>/dev/null || true
    
    if [[ "$font_installed" != true ]]; then
        log_error "❌ Font installation failed"
        return 1
    fi
}

configure_zsh() {
    log_info "Configuring Zsh as default shell..."

    if ! command -v zsh >/dev/null 2>&1; then
        log_warning "⚠️ Zsh not found, skipping shell configuration"
        return 0
    fi
    
    local zsh_path=$(which zsh)

    
    # Check if already zsh
    if [[ "$SHELL" == "$zsh_path" ]]; then
        log_success "✅ Zsh is already the default shell"
        return 0
    fi
    
    # Add zsh to /etc/shells if not present
    if ! grep -q "^$zsh_path$" /etc/shells 2>/dev/null; then

        log_info "Adding zsh to /etc/shells (requires sudo)..."

        if echo "$zsh_path" | sudo tee -a /etc/shells >/dev/null 2>&1; then
            log_success "✅ Added zsh to /etc/shells"
        else

            log_error "❌ Failed to add zsh to /etc/shells"
            return 1

        fi
    fi
    
    # Change default shell with proper password handling
    log_info "Changing default shell to zsh (requires password)..."
    echo -e "${YELLOW}You may be prompted for your password...${NC}"
    
    if sudo chsh -s "$zsh_path" "$USER" 2>/dev/null; then
        log_success "✅ Default shell changed to zsh. Restart terminal to apply."
    else

        log_warning "⚠️ Automated shell change failed. Run manually: sudo chsh -s $zsh_path $USER"
    fi
}


# Platform-specific package installation

install_packages_wsl() {

    local package_file=$1
    [[ ! -f "$package_file" || ! -s "$package_file" ]] && return 0
    

    log_info "Installing WSL packages..."
    local failed_packages=()
    
    # Update first
    sudo apt update >/dev/null 2>&1 || true
    
    while IFS= read -r package; do
        [[ -z "$package" || "$package" =~ ^[[:space:]]*# ]] && continue
        
        if sudo apt install -y "$package" >/dev/null 2>&1; then
            echo -n "."
        else
            failed_packages+=("$package")

        fi
    done < "$package_file"
    
    echo
    [[ ${#failed_packages[@]} -gt 0 ]] && {

        log_warning "Failed WSL packages (${#failed_packages[@]}): ${failed_packages[*]}"
    }
}

install_packages_arch() {
    local package_file=$1
    [[ ! -f "$package_file" || ! -s "$package_file" ]] && return 0
    
    log_info "Installing Arch packages..."
    local failed_packages=()
    
    while IFS= read -r package; do
        [[ -z "$package" || "$package" =~ ^[[:space:]]*# ]] && continue

        
        if sudo pacman -S --noconfirm "$package" >/dev/null 2>&1; then
            echo -n "."
        elif command -v yay >/dev/null && yay -S --noconfirm "$package" >/dev/null 2>&1; then
            echo -n "."
        else
            failed_packages+=("$package")
        fi
    done < "$package_file"
    
    echo

    [[ ${#failed_packages[@]} -gt 0 ]] && {
        log_warning "Failed Arch packages (${#failed_packages[@]}): ${failed_packages[*]}"
    }

}


install_packages_mac() {
    local package_file=$1
    [[ ! -f "$package_file" || ! -s "$package_file" ]] && return 0
    

    log_info "Installing macOS packages..."
    local failed_packages=()
    
    # Install Homebrew if needed
    if ! command -v brew >/dev/null; then
        log_info "Installing Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || {
            log_error "Failed to install Homebrew"
            return 1
        }
        eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null || eval "$(/usr/local/bin/brew shellenv)" 2>/dev/null || true
    fi
    
    while IFS= read -r package; do
        [[ -z "$package" || "$package" =~ ^[[:space:]]*# ]] && continue
        
        if brew install "$package" >/dev/null 2>&1; then
            echo -n "."
        else
            failed_packages+=("$package")
        fi
    done < "$package_file"

    
    echo
    [[ ${#failed_packages[@]} -gt 0 ]] && {
        log_warning "Failed macOS packages (${#failed_packages[@]}): ${failed_packages[*]}"
    }
}

install_universal_packages() {
    local platform=$1
    
    # Cargo packages
    if [[ -f "config/packages.cargo" && -s "config/packages.cargo" ]]; then
        log_info "Installing Cargo packages..."
        
        if ! command -v cargo >/dev/null; then
            log_info "Installing Rust..."
            curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y >/dev/null 2>&1 || {
                log_warning "⚠️ Failed to install Rust"
                return 0
            }
            source ~/.cargo/env 2>/dev/null || true
        fi
        
        while IFS= read -r package; do
            [[ -z "$package" || "$package" =~ ^[[:space:]]*# ]] && continue
            cargo install "$package" >/dev/null 2>&1 && echo -n "." || echo -n "x"
        done < "config/packages.cargo"
        echo
    fi
    
    # Pip packages
    if [[ -f "config/packages.pip" && -s "config/packages.pip" ]]; then
        log_info "Installing Python packages..."
        while IFS= read -r package; do
            [[ -z "$package" || "$package" =~ ^[[:space:]]*# ]] && continue
            pip3 install --user "$package" >/dev/null 2>&1 && echo -n "." || echo -n "x"

        done < "config/packages.pip"
        echo
    fi
    
    # NPM packages
    if [[ -f "config/packages.npm" && -s "config/packages.npm" ]]; then
        log_info "Installing NPM packages..."
        while IFS= read -r package; do
            [[ -z "$package" || "$package" =~ ^[[:space:]]*# ]] && continue
            npm install -g "$package" >/dev/null 2>&1 && echo -n "." || echo -n "x"
        done < "config/packages.npm"
        echo

    fi
}

main() {
    local platform=$(detect_platform)
    [[ "$platform" == "unknown" ]] && { log_error "❌ Unsupported platform!"; exit 1; }
    
    log_info "🚀 Restoring system on platform: $platform"
    [[ -f config/system-info.txt ]] && { log_info "📋 Backup info:"; cat config/system-info.txt; echo; }
    
    # Install curated packages first (platform-specific)
    case $platform in
        "wsl") install_packages_wsl "config/packages.curated" ;;

        "arch") install_packages_arch "config/packages.curated" ;;
        "mac") install_packages_mac "config/packages.curated" ;;
    esac
    

    # Install universal packages
    install_universal_packages "$platform"
    
    # Font and shell configuration
    log_info "🎨 Configuring fonts and shell..."
    install_nerd_fonts "$platform" || log_warning "⚠️ Font installation had issues"
    configure_zsh || log_warning "⚠️ Shell configuration had issues"
    
    # Final summary
    echo
    log_success "✅ System restore completed!"
    
    echo
    log_info "📋 Manual steps remaining:"
    echo -e "${BLUE}  1.${NC} Restart terminal/Alacritty to apply changes"
    echo -e "${BLUE}  2.${NC} Restore your dotfiles"
    echo -e "${BLUE}  3.${NC} Firefox: Settings > General > Startup > 'Open previous windows and tabs'"
    echo -e "${BLUE}  4.${NC} Verify shell: ${GREEN}echo \$SHELL${NC} (should show zsh path)"

    
    if [[ "$platform" == "wsl" ]]; then
        echo
        log_info "💡 WSL + Alacritty Notes:"
        echo -e "${YELLOW}  - Use 'MesloLGLDZ Nerd Font' in Alacritty config${NC}"
    fi
}

main "$@"
