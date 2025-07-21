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
        "wsl-python-pip") echo "python3-pip" ;;
        "arch-python-pip") echo "python-pip" ;;

        "mac-python-pip") echo "python" ;;
        "wsl-nodejs") echo "nodejs npm" ;;
        "mac-nodejs") echo "node" ;;

        "arch-nodejs") echo "nodejs npm" ;;
        *) echo "$package" ;;

    esac
}


# Check if package is already installed
is_installed() {
    local platform=$1 manager=$2 package=$3
    case "$manager" in
        "curated"|"dotfile-deps")
            case $platform in
                "arch") pacman -Qi "$package" >/dev/null 2>&1 ;;
                "mac") brew list --formula "$package" >/dev/null 2>&1 || brew list --cask "$package" >/dev/null 2>&1 ;;
                "wsl") dpkg -l "$package" >/dev/null 2>&1 ;;
            esac ;;
        "cargo") cargo install --list 2>/dev/null | grep -q "^$package " ;;
        "pip") pip3 list --user 2>/dev/null | grep -q "^$package " ;;
        "npm") npm list -g --depth=0 2>/dev/null | grep -q " $package@" ;;
        "brew") brew list --formula "$package" >/dev/null 2>&1 ;;
        "cask") brew list --cask "$package" >/dev/null 2>&1 ;;
        "aur") pacman -Qi "$package" >/dev/null 2>&1 ;;
        *) return 1 ;;

    esac
}


# Bootstrap package managers FIRST
bootstrap_package_managers() {
    local platform=$1
    
    case $platform in
        "mac")
            if ! command -v brew >/dev/null 2>&1; then
                log_info "🍺 Installing Homebrew..."
                /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || return 1
                eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null || eval "$(/usr/local/bin/brew shellenv)" 2>/dev/null || true
            fi
            if ! command -v mas >/dev/null 2>&1; then
                brew install mas || log_warning "Failed to install mas"
            fi ;;
        "arch")
            if ! command -v yay >/dev/null 2>&1 && ! command -v paru >/dev/null 2>&1; then
                log_info "🏗️ Installing yay (AUR helper)..."
                sudo pacman -S --noconfirm git base-devel || return 1
                cd /tmp && git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si --noconfirm && cd .. && rm -rf yay && cd - >/dev/null
            fi ;;
    esac
    
    # Install language package managers from system packages first
    if [[ -f "config/packages.cargo" && -s "config/packages.cargo" ]] && ! command -v cargo >/dev/null 2>&1; then
        case $platform in
            "arch") sudo pacman -S --noconfirm rustup && rustup install stable ;;
            "mac") brew install rust ;;
            "wsl") curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y && source ~/.cargo/env ;;
        esac
    fi
}

install_nerd_fonts() {
    local platform=$1
    log_info "🎨 Installing Meslo Nerd Font..."
    
    local version=$(curl -s https://api.github.com/repos/ryanoasis/nerd-fonts/releases/latest 2>/dev/null | grep '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/' 2>/dev/null || echo "v3.2.1")
    local temp_dir="/tmp/nerd-fonts-$$"
    mkdir -p "$temp_dir" && cd "$temp_dir" || return 1
    
    if wget -q "https://github.com/ryanoasis/nerd-fonts/releases/download/$version/Meslo.zip" 2>/dev/null; then
        case $platform in
            "wsl")
                if unzip -q Meslo.zip "*.ttf" 2>/dev/null; then
                    for win_dir in "/mnt/c/Windows/Fonts" "/mnt/c/Users/$USER/AppData/Local/Microsoft/Windows/Fonts"; do

                        if [[ -d "$(dirname "$win_dir" 2>/dev/null)" ]] && cp *.ttf "$win_dir/" 2>/dev/null; then
                            log_success "✅ Fonts installed to Windows"
                            cd - >/dev/null && rm -rf "$temp_dir"

                            return 0
                        fi
                    done
                    mkdir -p ~/.local/share/fonts && cp *.ttf ~/.local/share/fonts/ && fc-cache -fv >/dev/null 2>&1
                fi ;;
            "mac")
                unzip -q Meslo.zip "*.ttf" 2>/dev/null && mkdir -p ~/Library/Fonts && cp *.ttf ~/Library/Fonts/ ;;
            "arch")
                mkdir -p ~/.local/share/fonts && unzip -q Meslo.zip -d ~/.local/share/fonts/ 2>/dev/null && fc-cache -fv >/dev/null 2>&1 ;;
        esac
    fi
    
    cd - >/dev/null && rm -rf "$temp_dir"

    log_success "✅ Fonts installed"
}

configure_zsh() {
    if ! command -v zsh >/dev/null 2>&1; then
        log_warning "⚠️ Zsh not found, skipping shell configuration"

        return 0
    fi
    
    local zsh_path=$(which zsh)
    if [[ "$SHELL" != "$zsh_path" ]]; then
        if ! grep -q "^$zsh_path$" /etc/shells 2>/dev/null; then
            echo "$zsh_path" | sudo tee -a /etc/shells >/dev/null || return 1
        fi
        sudo chsh -s "$zsh_path" "$USER" 2>/dev/null && log_success "✅ Default shell changed to zsh"
    fi
}

install_packages() {

    local platform=$1 manager=$2 package_file="config/packages.$manager"
    [[ ! -f "$package_file" || ! -s "$package_file" ]] && return 0
    
    log_info "📦 Installing $manager packages..."
    local failed=0 installed=0 skipped=0

    
    while IFS= read -r package; do
        [[ -z "$package" || "$package" =~ ^[[:space:]]*# ]] && continue

        
        if is_installed "$platform" "$manager" "$package"; then

            ((skipped++))
            continue
        fi
        

        local translated=$(translate_package "$platform" "$package")
        local success=false

        
        case $manager in
            "curated"|"dotfile-deps")
                case $platform in
                    "arch") sudo pacman -S --noconfirm $translated 2>/dev/null && success=true || 

                           { command -v yay >/dev/null && yay -S --noconfirm $translated 2>/dev/null && success=true; } ;;

                    "mac") for pkg in $translated; do brew install "$pkg" 2>/dev/null; done && success=true ;;
                    "wsl") sudo apt install -y $translated 2>/dev/null && success=true ;;
                esac ;;

            "cargo") cargo install "$package" 2>/dev/null && success=true ;;

            "pip") pip3 install --user "$package" 2>/dev/null && success=true ;;
            "npm") [[ "$package" != "lib" ]] && npm install -g "$package" 2>/dev/null && success=true ;;

            "brew") brew install "$package" 2>/dev/null && success=true ;;
            "cask") brew install --cask "$package" 2>/dev/null && success=true ;;
            "aur") { command -v yay >/dev/null && yay -S --noconfirm "$package" 2>/dev/null; } && success=true ;;
        esac
        

        if [[ "$success" == true ]]; then
            ((installed++))
        else
            ((failed++))
            echo -e "${RED}  ❌ $package${NC}"

        fi
    done < "$package_file"

    
    log_info "   Installed: $installed | Skipped: $skipped | Failed: $failed"
}

main() {
    local platform=$(detect_platform)
    [[ "$platform" == "unknown" ]] && { log_error "❌ Unsupported platform!"; exit 1; }
    
    log_info "🚀 Restoring system on platform: $platform"

    [[ -f config/system-info.txt ]] && { log_info "📋 Backup info:"; cat config/system-info.txt; echo; }
    
    # PHASE 1: Bootstrap package managers
    log_info "🔧 Phase 1: Bootstrapping package managers..."
    bootstrap_package_managers "$platform" || { log_error "❌ Bootstrap failed"; exit 1; }
    
    # PHASE 2: Update system
    log_info "📦 Phase 2: Updating system..."

    case $platform in
        "wsl") sudo apt update >/dev/null 2>&1 && sudo apt upgrade -y >/dev/null 2>&1 ;;

        "mac") command -v brew >/dev/null && { brew update >/dev/null 2>&1; brew upgrade >/dev/null 2>&1; } ;;
        "arch") sudo pacman -Syu --noconfirm >/dev/null 2>&1 ;;

    esac
    
    # PHASE 3: Install packages in priority order (system first, then language managers)
    log_info "📦 Phase 3: Installing packages..."

    for manager in curated dotfile-deps brew cask mas aur cargo pip npm; do
        install_packages "$platform" "$manager"

    done
    
    # PHASE 4: Configuration

    log_info "🎨 Phase 4: Configuring system..."
    install_nerd_fonts "$platform" || log_warning "⚠️ Font installation issues"
    configure_zsh "$platform" || log_warning "⚠️ Shell configuration issues"

    
    log_success "✅ System restore completed!"
    echo
    log_info "📋 Manual steps:"
    echo -e "${BLUE}  1.${NC} Restart terminal to apply changes"

    echo -e "${BLUE}  2.${NC} Restore your dotfiles"
    echo -e "${BLUE}  3.${NC} Install Mason dependencies: ${GREEN}:MasonInstall <package>${NC}"
}


main "$@"
