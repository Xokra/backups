
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


# Update PATH after installing language tools
update_environment() {
    # Update PATH for current session
    [[ -f ~/.cargo/env ]] && source ~/.cargo/env 2>/dev/null || true
    
    # Add common paths that might be missing
    export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"
    
    # Refresh npm if nodejs was just installed

    if command -v npm >/dev/null 2>&1; then

        npm config set fund false 2>/dev/null || true
    fi
}

# Bootstrap package managers with environment updates
bootstrap_package_managers() {
    local platform=$1
    local bootstrap_needed=false
    

    case $platform in
        "mac")
            if ! command -v brew >/dev/null 2>&1; then
                log_info "🍺 Installing Homebrew..."
                /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || return 1
                eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null || eval "$(/usr/local/bin/brew shellenv)" 2>/dev/null || true
                bootstrap_needed=true
            fi
            
            if ! command -v mas >/dev/null 2>&1; then
                log_info "🏪 Installing mas..."
                brew install mas || log_warning "Failed to install mas"
            fi
            ;;
            
        "arch")
            if ! command -v yay >/dev/null 2>&1 && ! command -v paru >/dev/null 2>&1; then
                log_info "🏗️ Installing yay..."

                sudo pacman -S --noconfirm git base-devel || return 1
                cd /tmp
                git clone https://aur.archlinux.org/yay.git
                cd yay && makepkg -si --noconfirm && cd .. && rm -rf yay
                cd - >/dev/null

                bootstrap_needed=true
            fi
            ;;
            
        "wsl")
            log_info "🐧 Using apt package manager"

            ;;
    esac
    
    # Install Rust if cargo packages exist but cargo is missing

    if [[ -f "config/packages.cargo" && -s "config/packages.cargo" ]] && ! command -v cargo >/dev/null 2>&1; then

        log_info "🦀 Installing Rust..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y || return 1
        bootstrap_needed=true
    fi
    
    # Update environment if we installed anything
    if [[ "$bootstrap_needed" == true ]]; then

        update_environment
        log_success "✅ Package managers bootstrapped and environment updated"
    fi
}


install_nerd_fonts() {
    local platform=$1
    log_info "Installing Meslo Nerd Font..."

    

    local version=$(curl -s https://api.github.com/repos/ryanoasis/nerd-fonts/releases/latest 2>/dev/null | grep '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/' 2>/dev/null || echo "v3.2.1")
    local temp_dir="/tmp/nerd-fonts-$$"
    local font_installed=false
    
    mkdir -p "$temp_dir" && cd "$temp_dir" || return 1
    
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
                            log_warning "⚠️ Fonts installed locally"
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
    [[ "$font_installed" == true ]]

}


configure_zsh() {

    log_info "Configuring Zsh as default shell..."
    if ! command -v zsh >/dev/null 2>&1; then
        log_warning "⚠️ Zsh not found, skipping shell configuration"
        return 0
    fi
    
    local zsh_path=$(which zsh)
    
    if ! grep -q "^$zsh_path$" /etc/shells 2>/dev/null; then

        echo "$zsh_path" | sudo tee -a /etc/shells >/dev/null || return 1
    fi
    
    if [[ "$SHELL" != "$zsh_path" ]]; then
        log_info "Changing default shell to zsh..."

        if sudo chsh -s "$zsh_path" "$USER" 2>/dev/null; then
            log_success "✅ Default shell changed to zsh"
        else
            return 1
        fi
    else
        log_success "✅ Zsh is already the default shell"

    fi
}

# Optimized package installation with deduplication
install_packages() {
    local platform=$1 manager=$2 package_file="config/packages.$manager"
    [[ ! -f "$package_file" || ! -s "$package_file" ]] && return 0

    

    log_info "Installing $manager packages..."
    local failed_packages=()

    local installed_packages=()
    
    while IFS= read -r package; do
        [[ -z "$package" || "$package" =~ ^[[:space:]]*# ]] && continue
        

        # Skip if already processed in this session

        local package_key="${manager}-${package}"
        if [[ " ${installed_packages[*]} " =~ " $package_key " ]]; then
            continue
        fi

        
        local translated_package=$(translate_package "$platform" "$package")
        local install_success=false
        
        case $manager in
            "system")
                case $platform in
                    "arch") 
                        if sudo pacman -S --noconfirm --needed $translated_package 2>/dev/null; then

                            install_success=true
                        else
                            command -v yay >/dev/null && yay -S --noconfirm --needed $translated_package 2>/dev/null && install_success=true ||

                            command -v paru >/dev/null && paru -S --noconfirm --needed $translated_package 2>/dev/null && install_success=true
                        fi ;;
                    "mac") 
                        for pkg in $translated_package; do
                            brew install "$pkg" 2>/dev/null || brew list "$pkg" >/dev/null 2>&1 || continue

                        done
                        install_success=true ;;
                    "wsl") 
                        sudo apt install -y $translated_package 2>/dev/null && install_success=true ;;
                esac ;;
            "cargo") 
                if ! cargo install --list 2>/dev/null | grep -q "^$translated_package "; then
                    cargo install "$translated_package" 2>/dev/null && install_success=true
                else
                    install_success=true

                fi ;;

            "pip") 

                if ! pip3 list --user 2>/dev/null | grep -q "^$translated_package "; then
                    pip3 install --user "$translated_package" 2>/dev/null && install_success=true

                else

                    install_success=true
                fi ;;
            "npm") 
                if [[ "$translated_package" != "lib" ]]; then
                    if ! npm list -g "$translated_package" >/dev/null 2>&1; then
                        npm install -g "$translated_package" 2>/dev/null && install_success=true
                    else
                        install_success=true
                    fi
                else
                    install_success=true

                fi ;;

            "brew") brew install "$translated_package" 2>/dev/null || brew list "$translated_package" >/dev/null 2>&1 && install_success=true ;;

            "cask") brew install --cask "$translated_package" 2>/dev/null || brew list --cask "$translated_package" >/dev/null 2>&1 && install_success=true ;;
            "mas") mas install "$translated_package" 2>/dev/null && install_success=true ;;
            "aur") 
                command -v yay >/dev/null && yay -S --noconfirm --needed "$translated_package" 2>/dev/null && install_success=true ||
                command -v paru >/dev/null && paru -S --noconfirm --needed "$translated_package" 2>/dev/null && install_success=true ;;
        esac
        
        if [[ "$install_success" == true ]]; then
            installed_packages+=("$package_key")

        else
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
    
    # PRIORITY 1: Bootstrap package managers first and update environment
    log_info "🔧 Bootstrapping package managers..."
    if ! bootstrap_package_managers "$platform"; then
        log_error "❌ Failed to bootstrap package managers"
        exit 1
    fi
    
    # PRIORITY 2: Update system

    log_info "📦 Updating system packages..."
    case $platform in
        "wsl") sudo apt update >/dev/null 2>&1 && sudo apt upgrade -y >/dev/null 2>&1 || log_warning "⚠️ System update failed" ;;
        "mac") command -v brew >/dev/null && { brew update >/dev/null 2>&1 && brew upgrade >/dev/null 2>&1; } || log_warning "⚠️ Homebrew update failed" ;;
        "arch") sudo pacman -Syu --noconfirm >/dev/null 2>&1 || log_warning "⚠️ System update failed" ;;
    esac
    

    # PRIORITY 3: Install system packages (deduplicated)

    log_info "🔧 Installing system packages..."
    install_packages "$platform" "system"
    

    # PRIORITY 4: Update environment again after system packages
    update_environment
    
    # PRIORITY 5: Install language packages

    for manager in cargo pip npm brew cask mas aur; do

        if [[ -f "config/packages.$manager" && -s "config/packages.$manager" ]]; then

            install_packages "$platform" "$manager"
        fi
    done
    
    # PRIORITY 6: Post-install configuration
    log_info "🎨 Configuring fonts and shell..."
    local config_failed=0
    install_nerd_fonts "$platform" || ((config_failed++))
    configure_zsh "$platform" || ((config_failed++))

    

    # Final summary

    echo
    if [[ $config_failed -eq 0 ]]; then
        log_success "✅ System restore completed successfully in single run!"
    else
        log_warning "⚠️ System restore completed with some configuration issues"
    fi
    
    echo

    log_info "📋 Manual steps remaining:"

    echo -e "${BLUE}  1.${NC} Restart terminal to apply changes"
    echo -e "${BLUE}  2.${NC} Restore your dotfiles"

    echo -e "${BLUE}  3.${NC} Install Mason dependencies: ${GREEN}:MasonInstall <package>${NC}"
    
    [[ "$platform" == "wsl" ]] && {
        echo -e "${YELLOW}💡 WSL: Use 'MesloLGLDZ Nerd Font' in Alacritty config${NC}"
    }
}


main "$@"
