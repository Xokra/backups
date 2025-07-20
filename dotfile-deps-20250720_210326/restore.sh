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
    log_info "🎨 Installing Meslo Nerd Font..."
    
    local temp_dir="/tmp/nerd-fonts-$$"
    mkdir -p "$temp_dir" && cd "$temp_dir" || return 1
    
    if wget -q "https://github.com/ryanoasis/nerd-fonts/releases/download/v3.2.1/Meslo.zip" 2>/dev/null; then
        case $platform in
            "wsl")
                if unzip -q Meslo.zip "*.ttf" 2>/dev/null && ls *.ttf >/dev/null 2>&1; then
                    for win_dir in "/mnt/c/Windows/Fonts" "/mnt/c/Users/$USER/AppData/Local/Microsoft/Windows/Fonts"; do
                        if [[ -d "$(dirname "$win_dir" 2>/dev/null)" ]]; then
                            mkdir -p "$win_dir" 2>/dev/null && cp *.ttf "$win_dir/" 2>/dev/null && {
                                log_success "✅ Fonts installed to Windows"
                                cd - >/dev/null && rm -rf "$temp_dir"
                                return 0

                            }

                        fi
                    done

                    # Fallback to local
                    mkdir -p ~/.local/share/fonts && cp *.ttf ~/.local/share/fonts/ && fc-cache -fv >/dev/null 2>&1
                fi
                ;;
            "mac")
                unzip -q Meslo.zip "*.ttf" 2>/dev/null && mkdir -p ~/Library/Fonts && cp *.ttf ~/Library/Fonts/
                ;;
            "arch")
                mkdir -p ~/.local/share/fonts && unzip -q Meslo.zip -d ~/.local/share/fonts/ && fc-cache -fv >/dev/null 2>&1
                ;;
        esac
        log_success "✅ Fonts installed"
    fi
    
    cd - >/dev/null && rm -rf "$temp_dir"
}

configure_zsh() {
    if ! command -v zsh >/dev/null; then
        log_warning "⚠️ Zsh not found, skipping shell configuration"
        return 0

    fi

    

    local zsh_path=$(which zsh)
    
    # Only change shell if not already zsh
    if [[ "$SHELL" != "$zsh_path" ]]; then
        log_info "🐚 Setting zsh as default shell..."
        if ! grep -q "^$zsh_path$" /etc/shells 2>/dev/null; then
            echo "$zsh_path" | sudo tee -a /etc/shells >/dev/null
        fi
        sudo chsh -s "$zsh_path" "$USER" && log_success "✅ Shell changed to zsh (restart terminal)"
    else

        log_success "✅ Zsh is already the default shell"
    fi

}


install_packages() {
    local platform=$1 manager=$2 package_file="config/packages.$manager"
    [[ ! -f "$package_file" || ! -s "$package_file" ]] && return 0
    
    log_info "📦 Installing $manager packages..."
    local failed_packages=() installed=0 total=$(wc -l < "$package_file")
    
    # Install package manager if needed

    case "$platform-$manager" in

        "mac-brew") 
            if ! command -v brew >/dev/null; then

                log_info "🍺 Installing Homebrew..."
                /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
                eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null || eval "$(/usr/local/bin/brew shellenv)" 2>/dev/null
            fi ;;
        "*-cargo") 
            if ! command -v cargo >/dev/null; then
                log_info "🦀 Installing Rust..."
                curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
                source ~/.cargo/env

            fi ;;
        "arch-aur") 
            if ! command -v yay >/dev/null; then
                log_info "🔧 Installing yay..."

                sudo pacman -S --noconfirm git base-devel
                cd /tmp && git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si --noconfirm
            fi ;;
    esac
    

    while IFS= read -r package; do

        [[ -z "$package" || "$package" =~ ^[[:space:]]*# ]] && continue
        
        echo -ne "${BLUE}[INFO]${NC} Installing $package ($(($installed + 1))/$total)...\r"
        
        local success=false
        case $manager in
            "curated")
                case $platform in

                    "arch") sudo pacman -S --noconfirm --needed "$package" >/dev/null 2>&1 && success=true ;;
                    "mac") brew install "$package" >/dev/null 2>&1 && success=true ;;
                    "wsl") sudo apt install -y "$package" >/dev/null 2>&1 && success=true ;;

                esac ;;
            "apt") sudo apt install -y "$package" >/dev/null 2>&1 && success=true ;;
            "snap") sudo snap install "$package" >/dev/null 2>&1 && success=true ;;
            "cargo") cargo install "$package" >/dev/null 2>&1 && success=true ;;
            "pip") pip3 install --user "$package" >/dev/null 2>&1 && success=true ;;
            "npm") npm install -g "$package" >/dev/null 2>&1 && success=true ;;
            "brew"|"cask") brew install ${manager:+--$manager} "$package" >/dev/null 2>&1 && success=true ;;
            "pacman") sudo pacman -S --noconfirm --needed "$package" >/dev/null 2>&1 && success=true ;;
            "aur") yay -S --noconfirm --needed "$package" >/dev/null 2>&1 && success=true ;;
        esac
        

        if [[ "$success" == true ]]; then

            ((installed++))
        else
            failed_packages+=("$package")
        fi
    done < "$package_file"
    
    echo # Clear progress line
    log_success "✅ Installed $installed/$total $manager packages"
    [[ ${#failed_packages[@]} -gt 0 ]] && log_warning "Failed: ${failed_packages[*]}"
}


main() {
    local platform=$(detect_platform)
    [[ "$platform" == "unknown" ]] && { log_error "❌ Unsupported platform!"; exit 1; }
    
    log_info "🚀 Smart restore for dotfile dependencies on: $platform"
    [[ -f config/system-info.txt ]] && { log_info "📋 Backup info:"; head -10 config/system-info.txt; echo; }
    
    # Update system
    log_info "🔄 Updating system..."
    case $platform in
        "wsl") sudo apt update && sudo apt upgrade -y ;;
        "mac") command -v brew >/dev/null && { brew update; brew upgrade; } ;;

        "arch") sudo pacman -Syu --noconfirm ;;
    esac

    

    # Install packages in smart order
    log_info "📦 Installing dotfile dependencies..."
    
    # Core essentials first
    install_packages "$platform" "curated"
    
    # Platform-specific discoveries
    case $platform in
        "wsl") 
            install_packages "$platform" "apt"
            install_packages "$platform" "snap"
            ;;
        "mac") 

            install_packages "$platform" "brew"

            install_packages "$platform" "cask"

            ;;
        "arch") 

            install_packages "$platform" "pacman"
            install_packages "$platform" "aur"

            ;;
    esac
    
    # Universal package managers

    install_packages "$platform" "cargo"
    install_packages "$platform" "pip"

    install_packages "$platform" "npm"

    
    # Configure environment
    log_info "🎨 Configuring environment..."
    install_nerd_fonts "$platform"
    configure_zsh

    

    echo
    log_success "✅ Dotfile dependencies restored!"
    log_info "📋 Next steps:"
    echo -e "${BLUE}  1.${NC} Restart terminal"
    echo -e "${BLUE}  2.${NC} Clone and restore your dotfiles"
    echo -e "${BLUE}  3.${NC} Enjoy your familiar environment!"
}

main "$@"
