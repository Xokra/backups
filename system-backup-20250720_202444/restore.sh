#!/bin/bash
set -euo pipefail


RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

detect_platform() {
    if [[ -n "${WSL_DISTRO_NAME:-}" ]] || { [[ -f /proc/version ]] && grep -qi "microsoft\|wsl" /proc/version 2>/dev/null; }; then
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

    log_info "🎨 Installing Meslo Nerd Font..."

    

    local version
    version=$(curl -s https://api.github.com/repos/ryanoasis/nerd-fonts/releases/latest 2>/dev/null | grep '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/' 2>/dev/null) || version="v3.2.1"
    local temp_dir="/tmp/nerd-fonts-$$"
    local font_installed=false

    
    mkdir -p "$temp_dir" || { log_error "Failed to create temp directory"; return 1; }
    cd "$temp_dir" || { log_error "Failed to enter temp directory"; return 1; }

    if wget -q "https://github.com/ryanoasis/nerd-fonts/releases/download/$version/Meslo.zip" 2>/dev/null; then
        case $platform in
            "wsl")
                if unzip -q Meslo.zip "*.ttf" 2>/dev/null && ls *.ttf >/dev/null 2>&1; then
                    # Try Windows font directories
                    local win_dirs=("/mnt/c/Windows/Fonts" "/mnt/c/Users/$USER/AppData/Local/Microsoft/Windows/Fonts")

                    for win_dir in "${win_dirs[@]}"; do
                        if [[ -d "$(dirname "$win_dir" 2>/dev/null)" ]]; then
                            if mkdir -p "$win_dir" 2>/dev/null && cp *.ttf "$win_dir/" 2>/dev/null; then
                                log_success "✅ Fonts installed to Windows: $win_dir"
                                font_installed=true
                                break
                            fi
                        fi

                    done
                    
                    # Fallback to local fonts
                    if [[ "$font_installed" != true ]]; then

                        mkdir -p ~/.local/share/fonts 2>/dev/null || true
                        if cp *.ttf ~/.local/share/fonts/ 2>/dev/null && command -v fc-cache >/dev/null 2>&1; then
                            fc-cache -fv >/dev/null 2>&1 && {
                                log_warning "⚠️ Fonts installed locally. For Windows Alacritty, install manually to Windows fonts."
                                font_installed=true

                            }
                        fi
                    fi

                fi
                ;;
            "mac")
                if unzip -q Meslo.zip "*.ttf" 2>/dev/null && ls *.ttf >/dev/null 2>&1; then
                    mkdir -p ~/Library/Fonts || { log_error "Failed to create font directory"; cd - >/dev/null; rm -rf "$temp_dir"; return 1; }
                    if cp *.ttf ~/Library/Fonts/; then
                        log_success "✅ Fonts installed to ~/Library/Fonts"
                        font_installed=true
                    fi
                fi
                ;;

            "arch")

                mkdir -p ~/.local/share/fonts 2>/dev/null || { log_error "Failed to create font directory"; cd - >/dev/null; rm -rf "$temp_dir"; return 1; }
                if unzip -q Meslo.zip -d ~/.local/share/fonts/ 2>/dev/null && command -v fc-cache >/dev/null 2>&1; then

                    fc-cache -fv >/dev/null 2>&1 && {
                        log_success "✅ Fonts installed and font cache updated"
                        font_installed=true
                    }
                fi
                ;;
        esac
    else

        log_error "❌ Failed to download font archive"
    fi
    
    cd - >/dev/null 2>&1 || true
    rm -rf "$temp_dir" 2>/dev/null || true
    
    if [[ "$font_installed" != true ]]; then
        log_error "❌ Font installation failed"

        return 1
    fi
}

configure_zsh() {
    log_info "🐚 Configuring Zsh as default shell..."

    if ! command -v zsh >/dev/null 2>&1; then
        log_warning "⚠️ Zsh not found, skipping shell configuration"

        return 0
    fi
    
    local zsh_path
    zsh_path=$(which zsh) || { log_error "Failed to get zsh path"; return 1; }
    
    # Add zsh to /etc/shells if not present
    if ! grep -q "^$zsh_path$" /etc/shells 2>/dev/null; then
        if ! echo "$zsh_path" | sudo tee -a /etc/shells >/dev/null; then
            log_error "❌ Failed to add zsh to /etc/shells"
            return 1
        fi
    fi
    
    # Change default shell if not already zsh
    if [[ "$SHELL" != "$zsh_path" ]]; then
        log_info "🔄 Changing default shell to zsh (may require password)..."
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
    
    log_info "📦 Installing $manager packages..."

    local failed_packages=()
    local total_packages
    total_packages=$(wc -l < "$package_file" 2>/dev/null) || total_packages=0
    local current=0

    

    # Install package manager if needed
    case "$platform-$manager" in
        "mac-brew") 
            if ! command -v brew >/dev/null 2>&1; then
                log_info "🍺 Installing Homebrew..."
                /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || { log_error "Failed to install Homebrew"; return 1; }
                # Try both possible paths for brew
                if [[ -f /opt/homebrew/bin/brew ]]; then

                    eval "$(/opt/homebrew/bin/brew shellenv)"
                elif [[ -f /usr/local/bin/brew ]]; then

                    eval "$(/usr/local/bin/brew shellenv)"
                fi
            fi ;;
        "mac-mas") 
            if ! command -v mas >/dev/null 2>&1; then

                brew install mas || { log_error "Failed to install mas"; return 1; }
            fi ;;
        "*-cargo") 
            if ! command -v cargo >/dev/null 2>&1; then
                log_info "🦀 Installing Rust..."
                curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y || { log_error "Failed to install Rust"; return 1; }
                # shellcheck source=/dev/null
                source ~/.cargo/env 2>/dev/null || true
            fi ;;

        "arch-aur") 
            if ! command -v yay >/dev/null 2>&1 && ! command -v paru >/dev/null 2>&1; then
                log_info "🔧 Installing yay..."

                sudo pacman -S --noconfirm git base-devel || { log_error "Failed to install AUR dependencies"; return 1; }

                local old_pwd="$PWD"
                cd /tmp || { log_error "Failed to change to /tmp"; return 1; }

                git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si --noconfirm

                cd "$old_pwd" || true
                rm -rf /tmp/yay 2>/dev/null || true
            fi ;;
        "wsl-snap")
            if ! command -v snap >/dev/null 2>&1; then

                log_info "📦 Installing snapd..."
                sudo apt update >/dev/null 2>&1 || true

                sudo apt install -y snapd || { log_error "Failed to install snapd"; return 1; }
            fi ;;
    esac
    

    while IFS= read -r package; do
        [[ -z "$package" || "$package" =~ ^[[:space:]]*# ]] && continue
        
        ((current++))
        printf "${BLUE}[INFO]${NC} Installing %s (%d/%d)...\r" "$package" "$current" "$total_packages"
        
        local install_success=false

        case $manager in
            "curated")
                case $platform in
                    "arch") 

                        if sudo pacman -S --noconfirm "$package" >/dev/null 2>&1; then

                            install_success=true
                        elif command -v yay >/dev/null 2>&1 && yay -S --noconfirm "$package" >/dev/null 2>&1; then
                            install_success=true

                        elif command -v paru >/dev/null 2>&1 && paru -S --noconfirm "$package" >/dev/null 2>&1; then
                            install_success=true
                        fi ;;

                    "mac") 

                        if brew install "$package" >/dev/null 2>&1; then
                            install_success=true
                        fi ;;
                    "wsl") 
                        if sudo apt install -y "$package" >/dev/null 2>&1; then
                            install_success=true
                        fi ;;
                esac ;;
            "apt") 
                if sudo apt install -y "$package" >/dev/null 2>&1; then
                    install_success=true
                fi ;;
            "snap") 
                if sudo snap install "$package" >/dev/null 2>&1; then
                    install_success=true
                fi ;;
            "cargo") 
                if cargo install "$package" >/dev/null 2>&1; then
                    install_success=true
                fi ;;
            "pip") 

                if pip3 install --user "$package" >/dev/null 2>&1; then

                    install_success=true
                fi ;;
            "npm") 
                if npm install -g "$package" >/dev/null 2>&1; then

                    install_success=true
                fi ;;
            "brew") 
                if brew install "$package" >/dev/null 2>&1; then
                    install_success=true
                fi ;;
            "cask") 
                if brew install --cask "$package" >/dev/null 2>&1; then
                    install_success=true

                fi ;;
            "mas") 
                if mas install "$package" >/dev/null 2>&1; then
                    install_success=true
                fi ;;
            "pacman") 
                if sudo pacman -S --noconfirm "$package" >/dev/null 2>&1; then
                    install_success=true
                fi ;;
            "aur") 
                if command -v yay >/dev/null 2>&1 && yay -S --noconfirm "$package" >/dev/null 2>&1; then
                    install_success=true
                elif command -v paru >/dev/null 2>&1 && paru -S --noconfirm "$package" >/dev/null 2>&1; then
                    install_success=true

                fi ;;

        esac

        
        if [[ "$install_success" != true ]]; then
            failed_packages+=("$package")
        fi
    done < "$package_file"
    
    echo # Clear the progress line
    
    if [[ ${#failed_packages[@]} -gt 0 ]]; then
        log_warning "Failed to install ${#failed_packages[@]} $manager packages:"
        printf "${RED}  ❌ %s${NC}\n" "${failed_packages[@]}"
    fi

}


update_system() {

    local platform=$1
    log_info "🔄 Updating system packages..."
    
    case $platform in
        "wsl") 
            printf "${BLUE}[INFO]${NC} Running apt update...\r"
            if sudo apt update >/dev/null 2>&1; then
                printf "${BLUE}[INFO]${NC} Running apt upgrade...\r"
                if sudo apt upgrade -y >/dev/null 2>&1; then
                    log_success "System updated successfully"

                else

                    log_warning "⚠️ System upgrade failed, continuing..."

                fi
            else

                log_warning "⚠️ System update failed, continuing..."
            fi
            ;;
        "mac") 
            if command -v brew >/dev/null 2>&1; then
                printf "${BLUE}[INFO]${NC} Updating Homebrew...\r"
                if brew update >/dev/null 2>&1 && brew upgrade >/dev/null 2>&1; then
                    log_success "Homebrew updated successfully"
                else

                    log_warning "⚠️ Homebrew update failed, continuing..."
                fi
            fi

            ;;

        "arch") 
            printf "${BLUE}[INFO]${NC} Running pacman -Syu...\r"
            if sudo pacman -Syu --noconfirm >/dev/null 2>&1; then
                log_success "System updated successfully"
            else

                log_warning "⚠️ System update failed, continuing..."
            fi
            ;;
    esac

}

main() {
    local platform
    platform=$(detect_platform)
    [[ "$platform" == "unknown" ]] && { log_error "❌ Unsupported platform!"; exit 1; }

    

    log_info "🚀 Restoring system on platform: $platform"
    if [[ -f config/system-info.txt ]]; then

        log_info "📋 Backup info:"
        cat config/system-info.txt
        echo

    fi

    

    # Update system

    update_system "$platform"
    
    # Install packages
    log_info "🔧 Installing packages..."
    
    # Install curated packages first
    if [[ -f "config/packages.curated" && -s "config/packages.curated" ]]; then
        install_packages "$platform" "curated"
    fi
    
    # Install platform-specific packages

    case $platform in
        "wsl")
            for manager in apt snap; do

                if [[ -f "config/packages.$manager" && -s "config/packages.$manager" ]]; then
                    install_packages "$platform" "$manager"
                fi
            done
            ;;
        "mac")
            for manager in brew cask mas; do

                if [[ -f "config/packages.$manager" && -s "config/packages.$manager" ]]; then

                    install_packages "$platform" "$manager"
                fi
            done
            ;;
        "arch")
            for manager in pacman aur; do
                if [[ -f "config/packages.$manager" && -s "config/packages.$manager" ]]; then

                    install_packages "$platform" "$manager"
                fi
            done
            ;;
    esac

    

    # Universal packages
    for manager in cargo pip npm; do
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
    
    if ! configure_zsh; then
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


# Check if script is being sourced or executed
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

