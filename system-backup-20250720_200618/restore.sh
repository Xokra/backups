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

# Package translation table
translate_package() {

    local package=$1 platform=$2
    
    case "$package" in

        "python-pip")
            case $platform in
                "wsl") echo "python3-pip" ;;

                "mac") echo "python" ;;
                "arch") echo "python-pip" ;;
            esac ;;
        "nodejs")

            case $platform in
                "wsl") echo "nodejs npm" ;;
                "mac") echo "node npm" ;;
                "arch") echo "nodejs npm" ;;
            esac ;;
        "fontconfig")
            case $platform in
                "wsl") echo "fontconfig" ;;
                "mac") echo "" ;; # Built-in on macOS
                "arch") echo "fontconfig" ;;
            esac ;;
        *)

            echo "$package" ;;
    esac
}

install_nerd_fonts() {
    local platform=$1
    log_info "Installing Meslo Nerd Font..."
    
    local version=$(curl -s https://api.github.com/repos/ryanoasis/nerd-fonts/releases/latest 2>/dev/null | grep '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/' 2>/dev/null || echo "v3.2.1")
    local temp_dir="/tmp/nerd-fonts-$$"

    local font_installed=false
    
    mkdir -p "$temp_dir" && cd "$temp_dir" || { log_error "Failed to create temp directory"; return 1; }
    
    log_info "Downloading font archive..."
    if wget -q --show-progress "https://github.com/ryanoasis/nerd-fonts/releases/download/$version/Meslo.zip" 2>/dev/null; then
        log_info "Extracting and installing fonts..."
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
                mkdir -p ~/.local/share/fonts 2>/dev/null && unzip -q Meslo.zip -d ~/.local/share/fonts/ 2>/dev/null && {
                    log_info "Updating font cache..."
                    fc-cache -fv >/dev/null 2>&1 && {
                        log_success "✅ Fonts installed and font cache updated"
                        font_installed=true
                    }
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
    

    # Add zsh to /etc/shells if not present

    if ! grep -q "^$zsh_path$" /etc/shells 2>/dev/null; then
        log_info "Adding zsh to /etc/shells..."
        echo "$zsh_path" | sudo tee -a /etc/shells >/dev/null || {
            log_error "❌ Failed to add zsh to /etc/shells"
            return 1
        }

    fi
    

    # Change default shell if not already zsh
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
    
    local package_count=$(wc -l < "$package_file" 2>/dev/null || echo 0)

    [[ $package_count -eq 0 ]] && return 0
    
    log_info "Installing $package_count $manager packages..."
    local failed_packages=()
    local current=0
    local installed_count=0
    
    # Install package manager if needed (with error handling)
    case "$platform-$manager" in

        "mac-brew") 
            if ! command -v brew >/dev/null; then

                log_info "Installing Homebrew..."
                if ! /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" 2>/dev/null; then
                    log_warning "⚠️ Failed to install Homebrew, skipping brew packages"

                    return 0
                fi
                eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null || eval "$(/usr/local/bin/brew shellenv)" 2>/dev/null || true
            fi ;;
        "mac-mas") 
            if ! command -v mas >/dev/null; then
                if ! brew install mas >/dev/null 2>&1; then
                    log_warning "⚠️ Failed to install mas, skipping Mac App Store packages"
                    return 0
                fi
            fi ;;
        "*-cargo") 
            if ! command -v cargo >/dev/null; then
                log_info "Installing Rust..."
                if ! curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y >/dev/null 2>&1; then
                    log_warning "⚠️ Failed to install Rust, skipping cargo packages"
                    return 0

                fi
                source ~/.cargo/env 2>/dev/null || true
            fi ;;
        "arch-aur") 
            if ! command -v yay >/dev/null && ! command -v paru >/dev/null; then
                log_info "Installing yay..."
                if ! sudo pacman -S --noconfirm git base-devel >/dev/null 2>&1; then
                    log_warning "⚠️ Failed to install AUR dependencies, skipping AUR packages"
                    return 0
                fi

                local current_dir=$(pwd)
                if ! (cd /tmp && git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si --noconfirm && cd .. && rm -rf yay) >/dev/null 2>&1; then
                    log_warning "⚠️ Failed to install yay, skipping AUR packages"
                    cd "$current_dir" 2>/dev/null || true

                    return 0
                fi
                cd "$current_dir" 2>/dev/null || true
            fi ;;
        "wsl-snap")

            if ! command -v snap >/dev/null; then
                log_info "Installing snapd..."
                if ! sudo apt install -y snapd >/dev/null 2>&1; then
                    log_warning "⚠️ Failed to install snapd, skipping snap packages"
                    return 0

                fi
            fi ;;
    esac
    
    # Process packages with bulletproof error handling
    while IFS= read -r package || [[ -n "$package" ]]; do
        # Skip empty lines and comments
        [[ -z "$package" || "$package" =~ ^[[:space:]]*# || "$package" =~ ^[[:space:]]*$ ]] && continue
        
        ((current++))
        
        # Show progress with timeout protection
        printf "\r${BLUE}[INFO]${NC} Installing package $current/$package_count: %-30s" "$(echo "$package" | cut -c1-30)"

        
        local install_success=false
        local error_msg=""
        
        # Wrap everything in timeout and error handling
        if timeout 300 bash -c "
            set -euo pipefail
            # Translate package name for current platform
            if [[ '$manager' == 'universal' ]]; then
                case '$package' in
                    'python-pip')
                        case '$platform' in
                            'wsl') packages='python3-pip' ;;
                            'mac') packages='python' ;;

                            'arch') packages='python-pip' ;;

                        esac ;;
                    'nodejs')
                        case '$platform' in
                            'wsl') packages='nodejs npm' ;;
                            'mac') packages='node npm' ;;
                            'arch') packages='nodejs npm' ;;
                        esac ;;

                    'fontconfig')
                        case '$platform' in
                            'wsl') packages='fontconfig' ;;
                            'mac') packages='' ;;

                            'arch') packages='fontconfig' ;;

                        esac ;;
                    *) packages='$package' ;;
                esac
                
                [[ -z \"\$packages\" ]] && exit 0  # Skip if empty
                
                # Install translated packages

                case '$platform' in
                    'arch') 
                        for pkg in \$packages; do
                            sudo pacman -S --noconfirm \"\$pkg\" && exit 0
                            command -v yay >/dev/null && yay -S --noconfirm \"\$pkg\" && exit 0
                        done
                        exit 1 ;;
                    'mac') 
                        for pkg in \$packages; do
                            brew install \"\$pkg\" && exit 0
                        done
                        exit 1 ;;

                    'wsl') 
                        for pkg in \$packages; do
                            sudo apt install -y \$pkg && exit 0
                        done

                        exit 1 ;;
                esac
            else
                # Install package directly
                case '$manager' in
                    'apt') sudo apt install -y '$package' ;;
                    'snap') sudo snap install '$package' ;;
                    'cargo') cargo install '$package' ;;
                    'pip') pip3 install --user '$package' ;;
                    'npm') npm install -g '$package' ;;
                    'brew') brew install '$package' ;;
                    'cask') brew install --cask '$package' ;;
                    'mas') mas install '$package' ;;
                    'pacman') sudo pacman -S --noconfirm '$package' ;;

                    'aur') 
                        command -v yay >/dev/null && yay -S --noconfirm '$package' && exit 0
                        command -v paru >/dev/null && paru -S --noconfirm '$package' && exit 0
                        exit 1 ;;
                    'platform-specific')
                        case '$platform' in
                            'arch') sudo pacman -S --noconfirm '$package' ;;
                            'mac') brew install '$package' ;;

                            'wsl') sudo apt install -y '$package' ;;
                        esac ;;
                    *) exit 1 ;;

                esac
            fi

        " >/dev/null 2>&1; then
            install_success=true
            ((installed_count++))
        else
            case $? in
                124) error_msg="(timeout)" ;;
                *) error_msg="(failed)" ;;
            esac
            failed_packages+=("$package $error_msg")
        fi
        
        # Show immediate feedback
        if [[ "$install_success" == true ]]; then
            printf "\r${GREEN}[SUCCESS]${NC} Installed %-30s ($current/$package_count)\n" "$(echo "$package" | cut -c1-30)"
        else
            printf "\r${RED}[FAILED]${NC}  %-30s $error_msg ($current/$package_count)\n" "$(echo "$package" | cut -c1-30)"
        fi
        
    done < "$package_file"

    
    echo  # Ensure clean line
    

    # Final summary

    if [[ ${#failed_packages[@]} -gt 0 ]]; then

        log_warning "Installed $installed_count/$package_count $manager packages. Failed ${#failed_packages[@]}:"
        printf "${RED}  ❌ %s${NC}\n" "${failed_packages[@]}"
    else
        log_success "✅ All $installed_count $manager packages installed successfully"
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
    log_success "✅ System updated"
    
    # Install packages in order
    log_info "🔧 Installing packages..."
    for manager in universal platform-specific apt pacman brew snap cargo pip npm cask mas aur; do
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

main "$@"
