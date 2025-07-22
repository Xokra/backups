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


# FIXED: Comprehensive package name translation
translate_package() {
    local platform=$1 package=$2
    
    case "$platform-$package" in

        # Python pip differences
        "wsl-python-pip") echo "python3-pip" ;;
        "arch-python-pip") echo "python-pip" ;;
        "mac-python-pip") echo "python" ;;
        

        # Node.js differences (ensures npm gets installed)
        "wsl-nodejs") echo "nodejs npm" ;;
        "mac-nodejs") echo "node" ;;

        "arch-nodejs") echo "nodejs npm" ;;
        
        # Default: return original
        *) echo "$package" ;;
    esac
}

# FIXED: Robust package manager verification
verify_package_manager() {
    local manager=$1
    case $manager in
        "cargo") command -v cargo >/dev/null 2>&1 && cargo --version >/dev/null 2>&1 ;;
        "pip") command -v pip3 >/dev/null 2>&1 && pip3 --version >/dev/null 2>&1 ;;
        "npm") command -v npm >/dev/null 2>&1 && npm --version >/dev/null 2>&1 ;;
        "brew") command -v brew >/dev/null 2>&1 && brew --version >/dev/null 2>&1 ;;
        "mas") command -v mas >/dev/null 2>&1 && mas version >/dev/null 2>&1 ;;
        "yay") command -v yay >/dev/null 2>&1 ;;
        "paru") command -v paru >/dev/null 2>&1 ;;
        *) return 0 ;;
    esac
}

# FIXED: Bootstrap and verify package managers
bootstrap_package_managers() {
    local platform=$1
    
    case $platform in
        "mac")
            if ! command -v brew >/dev/null 2>&1; then
                log_info "🍺 Installing Homebrew..."
                /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || {

                    log_error "Failed to install Homebrew"
                    return 1
                }
                # Add to PATH for current session

                eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null || eval "$(/usr/local/bin/brew shellenv)" 2>/dev/null || true
            fi

            
            if ! command -v mas >/dev/null 2>&1; then
                log_info "🏪 Installing mas (Mac App Store CLI)..."
                brew install mas || log_warning "Failed to install mas"
            fi
            ;;
            
        "arch")
            if ! command -v yay >/dev/null 2>&1 && ! command -v paru >/dev/null 2>&1; then
                log_info "🏗️ Installing yay (AUR helper)..."
                sudo pacman -S --noconfirm git base-devel || {

                    log_error "Failed to install AUR dependencies"
                    return 1
                }

                cd /tmp
                git clone https://aur.archlinux.org/yay.git

                cd yay
                makepkg -si --noconfirm
                cd ..
                rm -rf yay

                cd - >/dev/null
            fi
            ;;
    esac

    

    # Install language package managers via system packages first
    if [[ -f "config/packages.cargo" && -s "config/packages.cargo" ]] && ! verify_package_manager "cargo"; then
        log_info "🦀 Installing Rust (needed for cargo packages)..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

        source ~/.cargo/env 2>/dev/null || export PATH="$HOME/.cargo/bin:$PATH"
    fi

    
    return 0
}

# FIXED: Collect and deduplicate all packages with proper ordering
collect_and_deduplicate_packages() {

    local platform=$1

    local temp_dir="/tmp/restore-$$"
    mkdir -p "$temp_dir"
    
    # System packages (must be first)
    local system_packages=()

    

    # Collect from all system package sources
    for source in curated dotfile-deps brew; do
        if [[ -f "config/packages.$source" ]]; then
            while IFS= read -r pkg; do

                [[ -z "$pkg" || "$pkg" =~ ^[[:space:]]*# ]] && continue
                # Translate and expand packages
                local translated=$(translate_package "$platform" "$pkg")
                for p in $translated; do

                    system_packages+=("$p")
                done
            done < "config/packages.$source"
        fi
    done
    
    # Deduplicate system packages
    printf '%s\n' "${system_packages[@]}" 2>/dev/null | sort -u > "$temp_dir/system_packages.final"
    

    # Language packages (second priority)

    for lang in cargo pip npm; do
        if [[ -f "config/packages.$lang" ]]; then
            grep -v "^[[:space:]]*#\|^[[:space:]]*$" "config/packages.$lang" 2>/dev/null | sort -u > "$temp_dir/${lang}_packages.final" || touch "$temp_dir/${lang}_packages.final"
        else
            touch "$temp_dir/${lang}_packages.final"
        fi
    done
    
    # Platform-specific packages (last)
    for pkg_type in cask mas aur; do
        if [[ -f "config/packages.$pkg_type" ]]; then
            grep -v "^[[:space:]]*#\|^[[:space:]]*$" "config/packages.$pkg_type" 2>/dev/null | sort -u > "$temp_dir/${pkg_type}_packages.final" || touch "$temp_dir/${pkg_type}_packages.final"

        else
            touch "$temp_dir/${pkg_type}_packages.final"
        fi

    done
    
    echo "$temp_dir"
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

# FIXED: Install packages with proper error handling and verification
install_package_batch() {
    local platform=$1 batch_type=$2 package_file=$3
    [[ ! -f "$package_file" || ! -s "$package_file" ]] && return 0
    
    log_info "Installing $batch_type packages..."
    local failed_packages=() success_count=0

    

    while IFS= read -r package; do

        [[ -z "$package" || "$package" =~ ^[[:space:]]*# ]] && continue
        
        local install_success=false
        case $batch_type in
            "system")
                case $platform in
                    "arch") 
                        if sudo pacman -S --noconfirm --needed "$package" 2>/dev/null; then

                            install_success=true
                        elif command -v yay >/dev/null && yay -S --noconfirm --needed "$package" 2>/dev/null; then
                            install_success=true
                        elif command -v paru >/dev/null && paru -S --noconfirm --needed "$package" 2>/dev/null; then
                            install_success=true

                        fi ;;

                    "mac") 
                        if brew install "$package" 2>/dev/null; then
                            install_success=true

                        fi ;;

                    "wsl") 
                        if sudo apt install -y "$package" 2>/dev/null; then
                            install_success=true
                        fi ;;

                esac ;;
            "cargo") 
                if verify_package_manager "cargo" && cargo install "$package" 2>/dev/null; then

                    install_success=true
                fi ;;
            "pip") 
                if verify_package_manager "pip" && pip3 install --user "$package" 2>/dev/null; then
                    install_success=true
                fi ;;
            "npm") 
                if verify_package_manager "npm" && [[ "$package" != "lib" ]] && npm install -g "$package" 2>/dev/null; then
                    install_success=true
                elif [[ "$package" == "lib" ]]; then
                    install_success=true  # Skip lib directory
                fi ;;
            "cask") 

                if verify_package_manager "brew" && brew install --cask "$package" 2>/dev/null; then
                    install_success=true
                fi ;;
            "mas") 
                if verify_package_manager "mas" && mas install "$package" 2>/dev/null; then
                    install_success=true
                fi ;;
            "aur") 
                if command -v yay >/dev/null && yay -S --noconfirm --needed "$package" 2>/dev/null; then
                    install_success=true
                elif command -v paru >/dev/null && paru -S --noconfirm --needed "$package" 2>/dev/null; then
                    install_success=true
                fi ;;
        esac
        

        if [[ "$install_success" == true ]]; then

            ((success_count++))

        else

            failed_packages+=("$package")
        fi
    done < "$package_file"
    
    if [[ $success_count -gt 0 ]]; then
        log_success "✅ Successfully installed $success_count $batch_type packages"
    fi
    
    if [[ ${#failed_packages[@]} -gt 0 ]]; then
        log_warning "Failed to install ${#failed_packages[@]} $batch_type packages:"
        printf "${RED}  ❌ %s${NC}\n" "${failed_packages[@]}"
    fi
}


main() {

    local platform=$(detect_platform)
    [[ "$platform" == "unknown" ]] && { log_error "❌ Unsupported platform!"; exit 1; }
    
    log_info "🚀 Restoring system on platform: $platform"
    [[ -f config/system-info.txt ]] && { log_info "📋 Backup info:"; cat config/system-info.txt; echo; }
    

    # PHASE 1: Bootstrap package managers
    log_info "🔧 Phase 1: Bootstrapping package managers..."
    if ! bootstrap_package_managers "$platform"; then

        log_error "❌ Failed to bootstrap package managers"
        exit 1
    fi
    
    # Update system first

    log_info "📦 Updating system packages..."
    case $platform in
        "wsl") 
            sudo apt update >/dev/null 2>&1 && sudo apt upgrade -y >/dev/null 2>&1 || log_warning "⚠️ System update failed, continuing..."
            ;;
        "mac") 
            if command -v brew >/dev/null; then
                brew update >/dev/null 2>&1 && brew upgrade >/dev/null 2>&1 || log_warning "⚠️ Homebrew update failed, continuing..."
            fi
            ;;
        "arch") 
            sudo pacman -Syu --noconfirm >/dev/null 2>&1 || log_warning "⚠️ System update failed, continuing..."
            ;;
    esac
    
    # PHASE 2: Collect and deduplicate packages
    log_info "🔧 Phase 2: Processing package lists..."
    local temp_dir=$(collect_and_deduplicate_packages "$platform")
    
    # PHASE 3: Install in correct order
    log_info "🔧 Phase 3: Installing packages in dependency order..."
    
    # Install system packages first (nodejs, python-pip, git, etc.)
    install_package_batch "$platform" "system" "$temp_dir/system_packages.final"
    
    # Verify language package managers are working after system install
    log_info "🔍 Verifying package managers..."
    source ~/.cargo/env 2>/dev/null || export PATH="$HOME/.cargo/bin:$PATH"

    hash -r  # Refresh command cache

    

    # Install language packages
    install_package_batch "$platform" "cargo" "$temp_dir/cargo_packages.final"

    install_package_batch "$platform" "pip" "$temp_dir/pip_packages.final"
    install_package_batch "$platform" "npm" "$temp_dir/npm_packages.final"
    
    # Install platform-specific packages
    install_package_batch "$platform" "cask" "$temp_dir/cask_packages.final"
    install_package_batch "$platform" "mas" "$temp_dir/mas_packages.final"
    install_package_batch "$platform" "aur" "$temp_dir/aur_packages.final"
    
    # Cleanup temp directory
    rm -rf "$temp_dir" 2>/dev/null || true

    
    # PHASE 4: Configuration
    log_info "🎨 Phase 4: Configuring fonts and shell..."

    local config_failed=0
    
    if ! install_nerd_fonts "$platform"; then
        ((config_failed++))
    fi

    
    if ! configure_zsh "$platform"; then
        ((config_failed++))
    fi
    
    # Final summary
    echo
    if [[ $config_failed -eq 0 ]]; then
        log_success "✅ System restore completed successfully in single run!"
    else
        log_warning "⚠️ System restore completed with some configuration issues"

    fi
    

    echo
    log_info "📋 Manual steps remaining:"
    echo -e "${BLUE}  1.${NC} Restart terminal/Alacritty to apply changes"
    echo -e "${BLUE}  2.${NC} Restore your dotfiles"

    echo -e "${BLUE}  3.${NC} Firefox: Settings > General > Startup > 'Open previous windows and tabs'"

    echo -e "${BLUE}  4.${NC} Verify shell: ${GREEN}echo \$SHELL${NC} (should show zsh path)"
    echo -e "${BLUE}  5.${NC} Install Mason dependencies: ${GREEN}:MasonInstall <package>${NC}"
    
    if [[ "$platform" == "wsl" ]]; then

        echo
        log_info "💡 WSL + Alacritty Notes:"

        echo -e "${YELLOW}  - If fonts don't appear, install manually to Windows fonts directory${NC}"
        echo -e "${YELLOW}  - Use 'MesloLGLDZ Nerd Font' in Alacritty config${NC}"
    fi
}


main "$@"
