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
translate_package() {
    local platform=$1 package=$2

    
    case "$platform-$package" in
        # Python pip differences
        "wsl-python-pip") echo "python3-pip" ;;
        "arch-python-pip") echo "python-pip" ;;
        "mac-python-pip") echo "python" ;;
        
        # Node.js differences (this ensures npm gets installed!)
        "wsl-nodejs") echo "nodejs npm" ;;

        "mac-nodejs") echo "node" ;;
        "arch-nodejs") echo "nodejs npm" ;;
        
        # Default: return original
        *) echo "$package" ;;
    esac
}

# Collect and deduplicate all packages
collect_packages() {

    local all_packages=()
    local system_packages=()
    local npm_packages=()

    local pip_packages=()
    local cargo_packages=()

    local brew_packages=()

    local cask_packages=()

    local mas_packages=()
    local aur_packages=()
    
    # Read all package files and categorize
    for file in config/packages.{curated,dotfile-deps,npm,pip,cargo,brew,cask,mas,aur}; do
        [[ ! -f "$file" || ! -s "$file" ]] && continue
        
        local category=$(basename "$file" | cut -d. -f2)
        while IFS= read -r package; do
            [[ -z "$package" || "$package" =~ ^[[:space:]]*# ]] && continue

            
            case $category in

                "curated"|"dotfile-deps") system_packages+=("$package") ;;
                "npm") npm_packages+=("$package") ;;
                "pip") pip_packages+=("$package") ;;
                "cargo") cargo_packages+=("$package") ;;
                "brew") brew_packages+=("$package") ;;
                "cask") cask_packages+=("$package") ;;
                "mas") mas_packages+=("$package") ;;

                "aur") aur_packages+=("$package") ;;
            esac
        done < "$file"
    done
    
    # Export arrays for use in main function
    printf '%s\n' "${system_packages[@]}" | sort -u > /tmp/system_packages 2>/dev/null || touch /tmp/system_packages
    printf '%s\n' "${npm_packages[@]}" | sort -u > /tmp/npm_packages 2>/dev/null || touch /tmp/npm_packages
    printf '%s\n' "${pip_packages[@]}" | sort -u > /tmp/pip_packages 2>/dev/null || touch /tmp/pip_packages
    printf '%s\n' "${cargo_packages[@]}" | sort -u > /tmp/cargo_packages 2>/dev/null || touch /tmp/cargo_packages
    printf '%s\n' "${brew_packages[@]}" | sort -u > /tmp/brew_packages 2>/dev/null || touch /tmp/brew_packages
    printf '%s\n' "${cask_packages[@]}" | sort -u > /tmp/cask_packages 2>/dev/null || touch /tmp/cask_packages
    printf '%s\n' "${mas_packages[@]}" | sort -u > /tmp/mas_packages 2>/dev/null || touch /tmp/mas_packages
    printf '%s\n' "${aur_packages[@]}" | sort -u > /tmp/aur_packages 2>/dev/null || touch /tmp/aur_packages
}

# FIXED: Platform-specific installation sequence
install_system_packages() {
    local platform=$1

    [[ ! -s /tmp/system_packages ]] && return 0
    
    log_info "🔧 Installing system packages..."
    local failed_packages=()
    
    while IFS= read -r package; do
        local translated_package=$(translate_package "$platform" "$package")
        local install_success=false
        

        case $platform in
            "arch") 

                if sudo pacman -S --noconfirm $translated_package 2>/dev/null; then
                    install_success=true
                else
                    command -v yay >/dev/null && yay -S --noconfirm $translated_package 2>/dev/null && install_success=true ||
                    command -v paru >/dev/null && paru -S --noconfirm $translated_package 2>/dev/null && install_success=true
                fi ;;
            "mac") 
                for pkg in $translated_package; do
                    brew install "$pkg" 2>/dev/null && install_success=true

                done ;;
            "wsl") 
                sudo apt install -y $translated_package 2>/dev/null && install_success=true ;;
        esac
        
        [[ "$install_success" != true ]] && failed_packages+=("$package")
    done < /tmp/system_packages
    
    [[ ${#failed_packages[@]} -gt 0 ]] && log_warning "Failed system packages: ${failed_packages[*]}"
}


# FIXED: Install language packages with proper PATH refresh
install_language_packages() {
    local platform=$1
    
    # Refresh PATH to pick up newly installed package managers
    export PATH="$PATH:$HOME/.cargo/bin:$HOME/.local/bin"
    hash -r 2>/dev/null || true
    

    # Install Rust packages
    if [[ -s /tmp/cargo_packages ]]; then
        log_info "🦀 Installing Cargo packages..."

        if ! command -v cargo >/dev/null 2>&1; then
            log_info "Installing Rust..."
            curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
            source ~/.cargo/env

        fi
        while IFS= read -r package; do

            cargo install "$package" 2>/dev/null || log_warning "Failed: $package"
        done < /tmp/cargo_packages

    fi
    

    # Install Python packages
    if [[ -s /tmp/pip_packages ]]; then
        log_info "🐍 Installing pip packages..."
        while IFS= read -r package; do
            pip3 install --user "$package" 2>/dev/null || log_warning "Failed: $package"
        done < /tmp/pip_packages
    fi
    
    # FIXED: Install npm packages with retry logic
    if [[ -s /tmp/npm_packages ]]; then
        log_info "📦 Installing npm packages..."
        

        # Wait for npm to be available and refresh PATH

        local npm_ready=false

        for i in {1..3}; do
            if command -v npm >/dev/null 2>&1; then
                npm_ready=true
                break
            fi
            log_info "Waiting for npm to be available... (attempt $i/3)"
            sleep 2
            hash -r 2>/dev/null || true
        done

        
        if [[ "$npm_ready" == true ]]; then
            while IFS= read -r package; do
                [[ "$package" != "lib" ]] && npm install -g "$package" 2>/dev/null || log_warning "Failed: $package"

            done < /tmp/npm_packages
        else

            log_error "npm not available after system package installation"
        fi
    fi

}


# FIXED: Bootstrap package managers first
bootstrap_package_managers() {
    local platform=$1
    
    case $platform in
        "mac")
            if ! command -v brew >/dev/null 2>&1; then
                log_info "🍺 Installing Homebrew..."

                /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
                eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null || eval "$(/usr/local/bin/brew shellenv)" 2>/dev/null || true
            fi
            ;;
        "arch")
            if ! command -v yay >/dev/null 2>&1 && ! command -v paru >/dev/null 2>&1; then
                log_info "🏗️ Installing yay..."
                sudo pacman -S --noconfirm git base-devel
                cd /tmp

                git clone https://aur.archlinux.org/yay.git
                cd yay
                makepkg -si --noconfirm
                cd - >/dev/null
                rm -rf /tmp/yay

            fi
            ;;
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
    fi
    
    cd - >/dev/null 2>&1 && rm -rf "$temp_dir" 2>/dev/null || true
    [[ "$font_installed" != true ]] && { log_error "❌ Font installation failed"; return 1; }
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
    
    # FIXED FLOW: Process packages first
    collect_packages
    
    # 1. Bootstrap package managers
    bootstrap_package_managers "$platform"
    
    # 2. Update system
    log_info "📦 Updating system packages..."
    case $platform in
        "wsl") sudo apt update && sudo apt upgrade -y ;;
        "mac") command -v brew >/dev/null && { brew update; brew upgrade; } ;;
        "arch") sudo pacman -Syu --noconfirm ;;
    esac
    
    # 3. Install system packages FIRST
    install_system_packages "$platform"
    
    # 4. Install language packages AFTER system packages are ready
    install_language_packages "$platform"
    
    # 5. Install platform-specific packages
    if [[ "$platform" == "mac" ]]; then
        [[ -s /tmp/brew_packages ]] && { log_info "🍺 Installing additional brew packages..."; while read -r pkg; do brew install "$pkg"; done < /tmp/brew_packages; }
        [[ -s /tmp/cask_packages ]] && { log_info "📱 Installing cask packages..."; while read -r pkg; do brew install --cask "$pkg"; done < /tmp/cask_packages; }

        [[ -s /tmp/mas_packages ]] && { log_info "🏪 Installing Mac App Store apps..."; while read -r pkg; do mas install "$pkg"; done < /tmp/mas_packages; }

    elif [[ "$platform" == "arch" ]] && [[ -s /tmp/aur_packages ]]; then
        log_info "🏗️ Installing AUR packages..."
        while read -r pkg; do
            command -v yay >/dev/null && yay -S --noconfirm "$pkg" ||

            command -v paru >/dev/null && paru -S --noconfirm "$pkg"
        done < /tmp/aur_packages
    fi
    
    # 6. Configure fonts and shell
    install_nerd_fonts "$platform" && configure_zsh

    
    # Cleanup

    rm -f /tmp/{system,npm,pip,cargo,brew,cask,mas,aur}_packages
    
    log_success "✅ System restore completed successfully!"

    echo
    log_info "📋 Manual steps remaining:"
    echo -e "${BLUE}  1.${NC} Restart terminal to apply changes"
    echo -e "${BLUE}  2.${NC} Restore your dotfiles"
    echo -e "${BLUE}  3.${NC} Install Mason dependencies: ${GREEN}:MasonInstall <package>${NC}"

}


main "$@"

