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

# Smart package name translation
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


# Check if command exists and refresh PATH
cmd_exists() { 
    command -v "$1" >/dev/null 2>&1 || { 
        hash -r 2>/dev/null || true
        command -v "$1" >/dev/null 2>&1
    }

}


# Bootstrap package managers with smart checks
bootstrap_package_managers() {
    local platform=$1
    
    case $platform in
        "mac")
            if ! cmd_exists brew; then
                log_info "🍺 Installing Homebrew..."
                /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || return 1
                eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null || eval "$(/usr/local/bin/brew shellenv)" 2>/dev/null || true

                hash -r 2>/dev/null || true
            fi
            if ! cmd_exists mas && cmd_exists brew; then
                log_info "🏪 Installing mas..."

                brew install mas || log_warning "Failed to install mas"

            fi
            ;;
        "arch")
            if ! cmd_exists yay && ! cmd_exists paru; then
                log_info "🏗️ Installing yay..."
                sudo pacman -S --noconfirm git base-devel || return 1
                cd /tmp && git clone https://aur.archlinux.org/yay.git

                cd yay && makepkg -si --noconfirm
                cd .. && rm -rf yay && cd - >/dev/null
                hash -r 2>/dev/null || true
            fi
            ;;

    esac
    
    # Install Rust if needed and cargo packages exist
    if [[ -f "config/packages.cargo" && -s "config/packages.cargo" ]] && ! cmd_exists cargo; then
        log_info "🦀 Installing Rust..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

        source ~/.cargo/env 2>/dev/null || true
        hash -r 2>/dev/null || true
    fi

}


# Smart font installation
install_nerd_fonts() {
    local platform=$1
    log_info "🎨 Installing Meslo Nerd Font..."
    
    local version=$(curl -s https://api.github.com/repos/ryanoasis/nerd-fonts/releases/latest 2>/dev/null | grep '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/' 2>/dev/null || echo "v3.2.1")
    local temp_dir="/tmp/nerd-fonts-$$"
    
    mkdir -p "$temp_dir" && cd "$temp_dir" || return 1
    
    if wget -q "https://github.com/ryanoasis/nerd-fonts/releases/download/$version/Meslo.zip"; then

        case $platform in
            "wsl")
                if unzip -q Meslo.zip "*.ttf" && ls *.ttf >/dev/null 2>&1; then
                    for win_dir in "/mnt/c/Windows/Fonts" "/mnt/c/Users/$USER/AppData/Local/Microsoft/Windows/Fonts"; do

                        if [[ -d "$(dirname "$win_dir" 2>/dev/null)" ]]; then
                            mkdir -p "$win_dir" 2>/dev/null && cp *.ttf "$win_dir/" 2>/dev/null && {

                                log_success "✅ Fonts installed to Windows: $win_dir"

                                cd - >/dev/null && rm -rf "$temp_dir"
                                return 0
                            }
                        fi

                    done
                    mkdir -p ~/.local/share/fonts && cp *.ttf ~/.local/share/fonts/ && fc-cache -fv >/dev/null 2>&1
                fi ;;
            "mac")
                unzip -q Meslo.zip "*.ttf" && mkdir -p ~/Library/Fonts && cp *.ttf ~/Library/Fonts/ ;;
            "arch")
                mkdir -p ~/.local/share/fonts && unzip -q Meslo.zip -d ~/.local/share/fonts/ && fc-cache -fv >/dev/null 2>&1 ;;

        esac
        log_success "✅ Fonts installed"
    fi
    
    cd - >/dev/null && rm -rf "$temp_dir"

}


# Configure Zsh with smart checks
configure_zsh() {
    if ! cmd_exists zsh; then

        log_warning "⚠️ Zsh not found, skipping shell configuration"
        return 0
    fi
    
    local zsh_path=$(which zsh)
    [[ "$SHELL" == "$zsh_path" ]] && { log_success "✅ Zsh already default shell"; return 0; }

    

    grep -q "^$zsh_path$" /etc/shells 2>/dev/null || echo "$zsh_path" | sudo tee -a /etc/shells >/dev/null
    
    log_info "🐚 Setting Zsh as default shell..."
    sudo chsh -s "$zsh_path" "$USER" && log_success "✅ Zsh set as default shell"

}


# Smart package installation with deduplication
install_packages() {
    local platform=$1 manager=$2 package_file="config/packages.$manager"

    [[ ! -f "$package_file" || ! -s "$package_file" ]] && return 0
    
    log_info "📦 Installing $manager packages..."
    local failed_packages=() installed_count=0

    
    while IFS= read -r package; do
        [[ -z "$package" || "$package" =~ ^[[:space:]]*# ]] && continue

        
        local translated_package=$(translate_package "$platform" "$package")
        local install_success=false
        

        # Smart installation check for expensive operations

        case $manager in
            "system-deduplicated")
                case $platform in
                    "arch") 
                        if pacman -Qi $translated_package >/dev/null 2>&1; then
                            install_success=true
                        elif sudo pacman -S --noconfirm $translated_package 2>/dev/null; then
                            install_success=true
                        elif cmd_exists yay && yay -S --noconfirm $translated_package 2>/dev/null; then

                            install_success=true
                        elif cmd_exists paru && paru -S --noconfirm $translated_package 2>/dev/null; then
                            install_success=true
                        fi ;;
                    "mac") 
                        for pkg in $translated_package; do
                            brew list --formula "$pkg" >/dev/null 2>&1 || brew install "$pkg" 2>/dev/null || continue

                        done

                        install_success=true ;;
                    "wsl") 
                        sudo apt install -y $translated_package 2>/dev/null && install_success=true ;;
                esac ;;
            "cargo") 

                cargo install --list 2>/dev/null | grep -q "^$translated_package " || {
                    cargo install "$translated_package" 2>/dev/null && install_success=true
                } && install_success=true ;;
            "pip") pip3 install --user "$translated_package" 2>/dev/null && install_success=true ;;
            "npm") 
                [[ "$translated_package" == "lib" ]] && install_success=true || {
                    npm list -g "$translated_package" >/dev/null 2>&1 || npm install -g "$translated_package" 2>/dev/null

                } && install_success=true ;;
            "brew") brew list --formula "$translated_package" >/dev/null 2>&1 || brew install "$translated_package" 2>/dev/null && install_success=true ;;
            "cask") brew list --cask "$translated_package" >/dev/null 2>&1 || brew install --cask "$translated_package" 2>/dev/null && install_success=true ;;
            "mas") mas install "$translated_package" 2>/dev/null && install_success=true ;;
            "aur") 
                if cmd_exists yay; then
                    yay -Q "$translated_package" >/dev/null 2>&1 || yay -S --noconfirm "$translated_package" 2>/dev/null && install_success=true
                elif cmd_exists paru; then
                    paru -Q "$translated_package" >/dev/null 2>&1 || paru -S --noconfirm "$translated_package" 2>/dev/null && install_success=true
                fi ;;
        esac
        
        if [[ "$install_success" == true ]]; then
            ((installed_count++))

        else
            failed_packages+=("$package")
        fi
    done < "$package_file"

    

    [[ $installed_count -gt 0 ]] && log_success "✅ Installed $installed_count $manager packages"
    [[ ${#failed_packages[@]} -gt 0 ]] && {
        log_warning "⚠️ Failed to install ${#failed_packages[@]} $manager packages:"

        printf "${RED}  ❌ %s${NC}\n" "${failed_packages[@]}"
    }
}

# Main restore function with proper sequencing

main() {
    local platform=$(detect_platform)
    [[ "$platform" == "unknown" ]] && { log_error "❌ Unsupported platform"; exit 1; }
    
    log_info "🚀 Smart single-run restore on: $platform"
    [[ -f config/system-info.txt ]] && { cat config/system-info.txt; echo; }
    

    # Phase 1: Bootstrap package managers

    log_info "🔧 Phase 1: Bootstrapping package managers..."
    bootstrap_package_managers "$platform" || { log_error "Bootstrap failed"; exit 1; }
    
    # Phase 2: System update
    log_info "📦 Phase 2: System update..."
    case $platform in
        "wsl") sudo apt update && sudo apt upgrade -y ;;
        "mac") cmd_exists brew && { brew update && brew upgrade; } ;;
        "arch") sudo pacman -Syu --noconfirm ;;
    esac >/dev/null 2>&1 || log_warning "⚠️ System update had issues"
    
    # Phase 3: Install packages in dependency order
    log_info "📦 Phase 3: Installing packages (smart order)..."

    for manager in system-deduplicated cargo pip npm brew cask mas aur; do
        install_packages "$platform" "$manager"
        hash -r 2>/dev/null || true  # Refresh PATH after each manager

    done
    
    # Phase 4: Configuration
    log_info "🎨 Phase 4: Configuration..."
    install_nerd_fonts "$platform" || log_warning "⚠️ Font installation had issues"
    configure_zsh || log_warning "⚠️ Zsh configuration had issues"
    
    # Success summary

    echo
    log_success "✅ Smart single-run restore completed!"
    echo
    log_info "📋 Next steps:"
    echo -e "${BLUE}  1.${NC} Restart terminal to apply changes"
    echo -e "${BLUE}  2.${NC} Restore dotfiles: ${GREEN}stow${NC} your configs"
    echo -e "${BLUE}  3.${NC} Verify shell: ${GREEN}echo \$SHELL${NC}"

    echo -e "${BLUE}  4.${NC} Install Mason LSPs: ${GREEN}:MasonInstall <package>${NC}"

    
    [[ "$platform" == "wsl" ]] && {
        echo -e "\n${YELLOW}💡 WSL Note: Use 'MesloLGLDZ Nerd Font' in Alacritty${NC}"
    }
}

main "$@"
