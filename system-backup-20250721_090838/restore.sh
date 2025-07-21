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


# Concept to package name translation (ONLY for different names)
translate_concept() {
    local platform=$1 concept=$2
    
    case "$platform-$concept" in
        # Only translate when names differ across platforms
        "wsl-runtime-python") echo "python3-pip" ;;
        "arch-runtime-python") echo "python-pip" ;;

        "mac-runtime-python") echo "python" ;;
        
        "mac-runtime-js") echo "node" ;;
        "wsl-runtime-js"|"arch-runtime-js") echo "nodejs npm" ;;
        
        "wsl-version-control"|"arch-version-control") echo "git" ;;
        "mac-version-control") echo "git" ;;
        
        "wsl-editor"|"arch-editor") echo "neovim" ;;
        "mac-editor") echo "neovim" ;;
        
        "wsl-shell"|"arch-shell"|"mac-shell") echo "zsh" ;;
        

        "wsl-multiplexer"|"arch-multiplexer"|"mac-multiplexer") echo "tmux" ;;
        
        "wsl-git-ui"|"arch-git-ui"|"mac-git-ui") echo "lazygit" ;;
        
        "wsl-downloader"|"arch-downloader"|"mac-downloader") echo "curl wget" ;;

        
        "wsl-json-parser"|"arch-json-parser"|"mac-json-parser") echo "jq" ;;
        

        "wsl-monitor"|"arch-monitor"|"mac-monitor") echo "htop" ;;

        
        "wsl-archiver"|"arch-archiver"|"mac-archiver") echo "unzip" ;;
        
        "wsl-dotfile-manager"|"arch-dotfile-manager"|"mac-dotfile-manager") echo "stow" ;;
        
        "wsl-fuzzy-finder"|"arch-fuzzy-finder"|"mac-fuzzy-finder") echo "zoxide" ;;
        
        # Platform-specific concepts
        "wsl-font-system") echo "fontconfig" ;;
        "arch-font-system") echo "fontconfig" ;;
        
        "wsl-pager"|"mac-pager") echo "less" ;;
        
        "mac-appstore-cli") echo "mas" ;;
        
        "arch-audio-control") echo "alsa-utils pulsemixer" ;;
        "arch-brightness-control") echo "brightnessctl" ;;
        "arch-status-bar") echo "polybar" ;;

        "arch-wallpaper") echo "feh" ;;
        "arch-terminal") echo "alacritty" ;;
        "arch-clipboard-x11") echo "xsel xclip" ;;
        "arch-browser") echo "firefox" ;;
        "arch-display-control") echo "xorg-xrandr" ;;
        "arch-rust-toolchain") echo "rustup" ;;
        
        # Default: return concept name (for same names across platforms)
        *) echo "$concept" ;;
    esac
}

# STEP 1: Install package managers first (CRITICAL ORDER)
install_package_managers() {
    local platform=$1
    log_info "🔧 Installing package managers..."
    
    case $platform in
        "mac")
            if ! command -v brew >/dev/null; then
                log_info "Installing Homebrew..."
                /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || { log_error "Failed to install Homebrew"; return 1; }
                eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null || eval "$(/usr/local/bin/brew shellenv)" 2>/dev/null || true
            fi
            if ! command -v mas >/dev/null && command -v brew >/dev/null; then
                brew install mas || log_warning "Failed to install mas"
            fi ;;

            
        "arch")
            if ! command -v yay >/dev/null && ! command -v paru >/dev/null; then
                log_info "Installing yay AUR helper..."
                sudo pacman -S --needed --noconfirm git base-devel || { log_error "Failed to install AUR dependencies"; return 1; }

                cd /tmp && git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si --noconfirm && cd .. && rm -rf yay || { log_error "Failed to install yay"; return 1; }
            fi ;;

            
        "wsl")
            # WSL usually has apt, but let's verify
            if ! command -v apt >/dev/null; then
                log_error "APT not found on WSL system"; return 1
            fi ;;
    esac
    
    # Install language toolchains
    if ! command -v cargo >/dev/null; then
        log_info "Installing Rust toolchain..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y || log_warning "Failed to install Rust"
        source ~/.cargo/env 2>/dev/null || true
    fi
}

# STEP 2: Install core concepts
install_concepts() {

    local platform=$1 concept_file="config/concepts.list"

    [[ ! -f "$concept_file" ]] && return 0
    
    log_info "📦 Installing core concepts..."
    local failed_concepts=()
    

    while IFS= read -r concept; do

        [[ -z "$concept" || "$concept" =~ ^[[:space:]]*# ]] && continue
        
        local packages=$(translate_concept "$platform" "$concept")
        local install_success=false
        
        case $platform in
            "arch")
                if sudo pacman -S --needed --noconfirm $packages 2>/dev/null; then
                    install_success=true

                else
                    command -v yay >/dev/null && yay -S --noconfirm $packages 2>/dev/null && install_success=true ||
                    command -v paru >/dev/null && paru -S --noconfirm $packages 2>/dev/null && install_success=true

                fi ;;

            "mac")

                brew install $packages 2>/dev/null && install_success=true ;;
            "wsl")
                sudo apt install -y $packages 2>/dev/null && install_success=true ;;
        esac
        
        if [[ "$install_success" != true ]]; then
            failed_concepts+=("$concept")
        fi
    done < "$concept_file"
    
    if [[ ${#failed_concepts[@]} -gt 0 ]]; then
        log_warning "Failed to install ${#failed_concepts[@]} concepts:"
        printf "${RED}  ❌ %s${NC}\n" "${failed_concepts[@]}"
    fi

}


# STEP 3: Install user packages (language managers)
install_user_packages() {

    local platform=$1
    log_info "🎯 Installing user packages..."
    
    for pkg_type in cargo pip npm brew cask mas aur; do
        local pkg_file="config/${pkg_type}.list"
        [[ ! -f "$pkg_file" || ! -s "$pkg_file" ]] && continue

        
        log_info "Installing $pkg_type packages..."
        local failed_packages=()
        

        while IFS= read -r package; do
            [[ -z "$package" || "$package" =~ ^[[:space:]]*# ]] && continue
            
            local install_success=false
            case $pkg_type in
                "cargo") cargo install "$package" 2>/dev/null && install_success=true ;;
                "pip") pip3 install --user "$package" 2>/dev/null && install_success=true ;;
                "npm") 
                    if [[ "$package" != "lib" ]]; then

                        npm install -g "$package" 2>/dev/null && install_success=true
                    else
                        install_success=true
                    fi ;;
                "brew") brew install "$package" 2>/dev/null && install_success=true ;;
                "cask") brew install --cask "$package" 2>/dev/null && install_success=true ;;
                "mas") mas install "$package" 2>/dev/null && install_success=true ;;
                "aur") 
                    command -v yay >/dev/null && yay -S --noconfirm "$package" 2>/dev/null && install_success=true ||
                    command -v paru >/dev/null && paru -S --noconfirm "$package" 2>/dev/null && install_success=true ;;
            esac
            
            if [[ "$install_success" != true ]]; then
                failed_packages+=("$package")
            fi
        done < "$pkg_file"
        
        if [[ ${#failed_packages[@]} -gt 0 ]]; then
            log_warning "Failed to install ${#failed_packages[@]} $pkg_type packages"
        fi
    done
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
    
    if ! grep -q "^$zsh_path$" /etc/shells 2>/dev/null; then
        echo "$zsh_path" | sudo tee -a /etc/shells >/dev/null || {
            log_error "❌ Failed to add zsh to /etc/shells"
            return 1
        }
    fi

    
    if [[ "$SHELL" != "$zsh_path" ]]; then
        log_info "Changing default shell to zsh (may require password)..."
        if sudo chsh -s "$zsh_path" "$USER" 2>/dev/null; then

            log_success "✅ Default shell changed to zsh. Restart terminal to apply."
        else
            log_error "❌ Failed to change default shell to zsh"
            return 1

        fi
    else

        log_success "✅ Zsh is already the default shell"
    fi

}


main() {
    local platform=$(detect_platform)
    [[ "$platform" == "unknown" ]] && { log_error "❌ Unsupported platform!"; exit 1; }
    

    log_info "🚀 Restoring system on platform: $platform"
    [[ -f config/system-info.txt ]] && { log_info "📋 Backup info:"; cat config/system-info.txt; echo; }
    
    # Update system first
    log_info "📦 Updating system..."
    case $platform in
        "wsl") sudo apt update >/dev/null 2>&1 && sudo apt upgrade -y >/dev/null 2>&1 || log_warning "System update failed" ;;
        "mac") command -v brew >/dev/null && { brew update >/dev/null 2>&1 && brew upgrade >/dev/null 2>&1; } || log_warning "Homebrew update failed" ;;
        "arch") sudo pacman -Syu --noconfirm >/dev/null 2>&1 || log_warning "System update failed" ;;
    esac
    
    # CRITICAL: Install in correct order
    log_info "🔧 Installing in correct order..."
    
    # Step 1: Package managers first

    install_package_managers "$platform" || log_error "Package manager installation failed"
    

    # Step 2: Core concepts
    install_concepts "$platform"
    
    # Step 3: User packages
    install_user_packages "$platform"
    
    # Step 4: Configuration

    log_info "🎨 Final configuration..."
    local config_failed=0
    
    if ! install_nerd_fonts "$platform"; then
        ((config_failed++))
    fi
    
    if ! configure_zsh "$platform"; then
        ((config_failed++))
    fi
    
    echo
    if [[ $config_failed -eq 0 ]]; then
        log_success "✅ System restore completed successfully!"

    else
        log_warning "⚠️ System restore completed with some issues"
    fi
    
    echo
    log_info "📋 Next steps:"
    echo -e "${BLUE}  1.${NC} Restart terminal to apply changes"
    echo -e "${BLUE}  2.${NC} Restore your dotfiles"
    echo -e "${BLUE}  3.${NC} Verify: ${GREEN}echo \$SHELL${NC} (should show zsh)"
    
    if [[ "$platform" == "wsl" ]]; then
        echo
        log_info "💡 WSL Notes:"
        echo -e "${YELLOW}  - Use 'MesloLGLDZ Nerd Font' in Alacritty config${NC}"
        echo -e "${YELLOW}  - Config: ~/.config/alacritty/alacritty.toml${NC}"
    fi
}

main "$@"
