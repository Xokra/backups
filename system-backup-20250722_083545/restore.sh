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


# FIXED: Ensure package managers are installed before using them
bootstrap_package_managers() {
    local platform=$1
    
    case $platform in
        "mac")

            # Install Homebrew if not present
            if ! command -v brew >/dev/null 2>&1; then

                log_info "🍺 Installing Homebrew..."
                /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || {
                    log_error "Failed to install Homebrew"
                    return 1
                }
                # Add to PATH for current session
                eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null || eval "$(/usr/local/bin/brew shellenv)" 2>/dev/null || true
            fi
            ;;
            
        "arch")

            # Install AUR helper if not present

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
        "wsl")
            # WSL uses apt, which should be available by default
            log_info "🐧 Using apt package manager"
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

                    # Try Windows directories first
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
    
    # Add zsh to /etc/shells if not present
    if ! grep -q "^$zsh_path$" /etc/shells 2>/dev/null; then
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


# FIXED: Collect, translate, dedupe and install in proper order
install_all_packages() {
    local platform=$1
    
    # Step 1: Collect all system packages from all sources
    local all_sys_packages=()
    local all_lang_packages=()
    
    # Collect system packages (curated + dotfile-deps + brew/aur)
    for file in config/packages.{curated,dotfile-deps,brew,aur}; do
        [[ -f "$file" && -s "$file" ]] || continue
        while IFS= read -r pkg; do
            [[ -z "$pkg" || "$pkg" =~ ^[[:space:]]*# ]] && continue
            all_sys_packages+=("$pkg")
        done < "$file"

    done
    
    # Collect language packages separately

    for file in config/packages.{cargo,pip,npm}; do

        [[ -f "$file" && -s "$file" ]] || continue

        local lang=$(basename "$file" | cut -d. -f2)
        while IFS= read -r pkg; do
            [[ -z "$pkg" || "$pkg" =~ ^[[:space:]]*# ]] && continue
            all_lang_packages+=("$lang:$pkg")
        done < "$file"
    done
    
    # Step 2: Translate and deduplicate system packages
    local translated_packages=()
    local seen_packages=()

    

    for pkg in "${all_sys_packages[@]}"; do
        local translated=$(translate_package "$platform" "$pkg")
        for t_pkg in $translated; do
            if [[ ! " ${seen_packages[*]} " =~ " ${t_pkg} " ]]; then
                translated_packages+=("$t_pkg")
                seen_packages+=("$t_pkg")

            fi

        done

    done
    
    # Step 3: Install system packages first
    if [[ ${#translated_packages[@]} -gt 0 ]]; then
        log_info "🔧 Installing ${#translated_packages[@]} system packages..."
        local sys_failed=()
        
        case $platform in
            "arch") 
                for pkg in "${translated_packages[@]}"; do
                    if ! sudo pacman -S --noconfirm "$pkg" 2>/dev/null; then
                        if command -v yay >/dev/null && ! yay -S --noconfirm "$pkg" 2>/dev/null; then

                            command -v paru >/dev/null && ! paru -S --noconfirm "$pkg" 2>/dev/null && sys_failed+=("$pkg")
                        fi
                    fi
                done ;;
            "mac") 

                for pkg in "${translated_packages[@]}"; do
                    brew install "$pkg" 2>/dev/null || sys_failed+=("$pkg")
                done ;;

            "wsl") 
                # Install in batches for efficiency
                if ! sudo apt install -y "${translated_packages[@]}" 2>/dev/null; then
                    # Fallback: install individually
                    for pkg in "${translated_packages[@]}"; do
                        sudo apt install -y "$pkg" 2>/dev/null || sys_failed+=("$pkg")
                    done
                fi ;;
        esac
        

        [[ ${#sys_failed[@]} -gt 0 ]] && log_warning "Failed system packages: ${sys_failed[*]}"
    fi
    
    # Step 4: Verify and setup language package managers
    log_info "🔧 Verifying package managers..."
    

    # Install Rust if needed and cargo packages exist
    if [[ -f config/packages.cargo && -s config/packages.cargo ]] && ! command -v cargo >/dev/null 2>&1; then
        log_info "🦀 Installing Rust..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

        source ~/.cargo/env 2>/dev/null || export PATH="$HOME/.cargo/bin:$PATH"
    fi

    

    # Refresh PATH to pick up newly installed tools
    hash -r 2>/dev/null || true

    
    # Step 5: Install language packages
    if [[ ${#all_lang_packages[@]} -gt 0 ]]; then

        log_info "📦 Installing ${#all_lang_packages[@]} language packages..."
        local lang_failed=()

        
        for lang_pkg in "${all_lang_packages[@]}"; do
            local lang="${lang_pkg%%:*}"

            local pkg="${lang_pkg#*:}"
            
            case $lang in
                "cargo") 
                    command -v cargo >/dev/null && cargo install "$pkg" 2>/dev/null || lang_failed+=("cargo:$pkg") ;;
                "pip") 
                    command -v pip3 >/dev/null && pip3 install --user "$pkg" 2>/dev/null || lang_failed+=("pip:$pkg") ;;

                "npm") 
                    if command -v npm >/dev/null 2>&1 && [[ "$pkg" != "lib" ]]; then
                        npm install -g "$pkg" 2>/dev/null || lang_failed+=("npm:$pkg")
                    fi ;;
            esac
        done
        
        [[ ${#lang_failed[@]} -gt 0 ]] && log_warning "Failed language packages: ${lang_failed[*]}"
    fi

    
    # Step 6: Install cask/mas packages (macOS only)
    if [[ $platform == "mac" ]]; then

        for file in config/packages.{cask,mas}; do

            [[ -f "$file" && -s "$file" ]] || continue
            local type=$(basename "$file" | cut -d. -f2)
            log_info "🍺 Installing $type packages..."
            
            while IFS= read -r pkg; do
                [[ -z "$pkg" || "$pkg" =~ ^[[:space:]]*# ]] && continue

                case $type in
                    "cask") brew install --cask "$pkg" 2>/dev/null || log_warning "Failed: $pkg" ;;
                    "mas") command -v mas >/dev/null && mas install "$pkg" 2>/dev/null || log_warning "Failed: $pkg" ;;
                esac
            done < "$file"
        done
    fi
}


main() {

    local platform=$(detect_platform)
    [[ "$platform" == "unknown" ]] && { log_error "❌ Unsupported platform!"; exit 1; }
    
    log_info "🚀 Restoring system on platform: $platform"
    [[ -f config/system-info.txt ]] && { log_info "📋 Backup info:"; cat config/system-info.txt; echo; }
    
    # FIXED: Bootstrap package managers FIRST
    log_info "🔧 Bootstrapping package managers..."

    if ! bootstrap_package_managers "$platform"; then
        log_error "❌ Failed to bootstrap package managers"
        exit 1

    fi

    

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
    

    # Install mas early on macOS
    if [[ $platform == "mac" ]] && ! command -v mas >/dev/null 2>&1; then
        log_info "🏪 Installing mas (Mac App Store CLI)..."
        brew install mas || log_warning "Failed to install mas"
    fi

    
    # FIXED: Install all packages in proper order
    install_all_packages "$platform"
    
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
    echo -e "${BLUE}  5.${NC} Install Mason dependencies: ${GREEN}:MasonInstall <package>${NC}"

    

    if [[ "$platform" == "wsl" ]]; then
        echo
        log_info "💡 WSL + Alacritty Notes:"
        echo -e "${YELLOW}  - If fonts don't appear, install manually to Windows fonts directory${NC}"
        echo -e "${YELLOW}  - Use 'MesloLGLDZ Nerd Font' in Alacritty config${NC}"

    fi
}

main "$@"
