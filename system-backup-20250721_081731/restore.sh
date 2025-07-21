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


# Cross-platform package name translation
translate_package_name() {
    local platform=$1 package=$2
    
    case "$platform:$package" in
        # Python pip differences
        "wsl:python-pip") echo "python3-pip" ;;
        "arch:python-pip") echo "python-pip" ;;
        "mac:python-pip") echo "python" ;;
        
        # Node.js differences  
        "mac:nodejs") echo "node" ;;
        
        # File utilities
        "wsl:fd") echo "fd-find" ;;
        "arch:fd") echo "fd" ;;
        "mac:fd") echo "fd" ;;
        
        # Different package names
        "wsl:ripgrep") echo "ripgrep" ;;

        "arch:ripgrep") echo "ripgrep" ;;
        "mac:ripgrep") echo "ripgrep" ;;
        
        # Default: return original
        *) echo "$package" ;;
    esac
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

install_packages() {
    local platform=$1 manager=$2 package_file="config/packages.$manager"
    [[ ! -f "$package_file" || ! -s "$package_file" ]] && return 0
    
    log_info "Installing $manager packages..."
    local failed_packages=()
    
    # Install package manager if needed
    case "$platform-$manager" in
        "mac-brew") 
            if ! command -v brew >/dev/null; then
                log_info "Installing Homebrew..."

                /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || { log_error "Failed to install Homebrew"; return 1; }
                eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null || eval "$(/usr/local/bin/brew shellenv)" 2>/dev/null || true
            fi ;;
        "mac-mas") 
            if ! command -v mas >/dev/null; then
                brew install mas || { log_error "Failed to install mas"; return 1; }

            fi ;;
        "*-cargo") 
            if ! command -v cargo >/dev/null; then
                log_info "Installing Rust..."
                curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y || { log_error "Failed to install Rust"; return 1; }
                source ~/.cargo/env || true
            fi ;;
        "arch-aur") 
            if ! command -v yay >/dev/null && ! command -v paru >/dev/null; then
                log_info "Installing yay..."

                sudo pacman -S --noconfirm git base-devel || { log_error "Failed to install AUR dependencies"; return 1; }
                cd /tmp && git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si --noconfirm && cd .. && rm -rf yay || { log_error "Failed to install yay"; return 1; }
            fi ;;
        "wsl-snap")
            if ! command -v snap >/dev/null; then

                log_info "Installing snapd..."
                sudo apt install -y snapd || { log_error "Failed to install snapd"; return 1; }
            fi ;;
    esac
    
    while IFS= read -r package; do
        [[ -z "$package" || "$package" =~ ^[[:space:]]*# ]] && continue
        
        # Translate package name for platform compatibility
        local translated_package=$(translate_package_name "$platform" "$package")
        
        local install_success=false
        case $manager in

            "curated")
                case $platform in
                    "arch") 
                        if sudo pacman -S --noconfirm "$translated_package" 2>/dev/null; then
                            install_success=true
                        else
                            command -v yay >/dev/null && yay -S --noconfirm "$translated_package" 2>/dev/null && install_success=true ||
                            command -v paru >/dev/null && paru -S --noconfirm "$translated_package" 2>/dev/null && install_success=true
                        fi ;;
                    "mac") brew install "$translated_package" 2>/dev/null && install_success=true ;;
                    "wsl") sudo apt install -y "$translated_package" 2>/dev/null && install_success=true ;;
                esac ;;
            "apt") sudo apt install -y "$translated_package" 2>/dev/null && install_success=true ;;
            "snap") sudo snap install "$translated_package" 2>/dev/null && install_success=true ;;
            "cargo") cargo install "$translated_package" 2>/dev/null && install_success=true ;;
            "pip") pip3 install --user "$translated_package" 2>/dev/null && install_success=true ;;
            "npm") 
                if [[ "$translated_package" != "lib" ]]; then
                    npm install -g "$translated_package" 2>/dev/null && install_success=true
                else
                    install_success=true
                fi ;;
            "brew") brew install "$translated_package" 2>/dev/null && install_success=true ;;
            "cask") brew install --cask "$translated_package" 2>/dev/null && install_success=true ;;
            "mas") mas install "$translated_package" 2>/dev/null && install_success=true ;;
            "pacman") sudo pacman -S --noconfirm "$translated_package" 2>/dev/null && install_success=true ;;
            "aur") 
                command -v yay >/dev/null && yay -S --noconfirm "$translated_package" 2>/dev/null && install_success=true ||
                command -v paru >/dev/null && paru -S --noconfirm "$translated_package" 2>/dev/null && install_success=true ;;
        esac
        

        if [[ "$install_success" != true ]]; then
            failed_packages+=("$package")
        fi
    done < "$package_file"
    
    if [[ ${#failed_packages[@]} -gt 0 ]]; then
        log_warning "Failed to install ${#failed_packages[@]} $manager packages:"
        printf "${RED}  ❌ %s${NC}\n" "${failed_packages[@]}"
    fi
}

main() {
    local platform=$(detect_platform)
    [[ "$platform" == "unknown" ]] && { log_error "❌ Unsupported platform!"; exit 1; }

    
    log_info "🚀 Restoring system on platform: $platform"
    [[ -f config/system-info.txt ]] && { log_info "📋 Backup info:"; cat config/system-info.txt; echo; }
    
    # Update system
    log_info "📦 Updating system packages..."
    case $platform in
        "wsl") 
            sudo apt update >/dev/null 2>&1 && sudo apt upgrade -y >/dev/null 2>&1 || { log_warning "⚠️ System update failed, continuing..."; }

            ;;
        "mac") 
            if command -v brew >/dev/null; then
                brew update >/dev/null 2>&1 && brew upgrade >/dev/null 2>&1 || { log_warning "⚠️ Homebrew update failed, continuing..."; }
            fi
            ;;

        "arch") 
            sudo pacman -Syu --noconfirm >/dev/null 2>&1 || { log_warning "⚠️ System update failed, continuing..."; }
            ;;
    esac
    
    # Install packages

    log_info "🔧 Installing packages..."
    for manager in curated apt pacman brew snap cargo pip npm cask mas aur; do

        if [[ -f "config/packages.$manager" && -s "config/packages.$manager" ]]; then

            install_packages "$platform" "$manager"
        fi
    done
    
    # Post-install configuration
    log_info "🎨 Configuring fonts and shell..."

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
        log_success "✅ System restore completed successfully!"
    else
        log_warning "⚠️ System restore completed with some issues"
    fi
    
    echo

    log_info "📋 Manual steps remaining:"
    echo -e "${BLUE}  1.${NC} Restart terminal/Alacritty to apply changes"
    echo -e "${BLUE}  2.${NC} Restore your dotfiles"
    echo -e "${BLUE}  3.${NC} Firefox: Settings > General > Startup > 'Open previous windows and tabs'"
    echo -e "${BLUE}  4.${NC} Verify shell: ${GREEN}echo \$SHELL${NC} (should show zsh path)"
    
    if [[ "$platform" == "wsl" ]]; then

        echo
        log_info "💡 WSL + Alacritty Notes:"
        echo -e "${YELLOW}  - If fonts don't appear, install manually to Windows fonts directory${NC}"
        echo -e "${YELLOW}  - Use 'MesloLGLDZ Nerd Font' in Alacritty config${NC}"
    fi
}


main "$@"
