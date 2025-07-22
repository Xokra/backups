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
collect_all_packages() {
    local all_packages=()
    local system_packages=()
    local language_packages=()
    local platform_packages=()
    
    # Collect from all package files
    for pkg_file in config/packages.{curated,dotfile-deps,cargo,pip,npm,brew,cask,mas,aur}; do
        [[ -f "$pkg_file" && -s "$pkg_file" ]] || continue
        
        local pkg_type=$(basename "$pkg_file" | cut -d. -f2)
        while IFS= read -r package; do
            [[ -z "$package" || "$package" =~ ^[[:space:]]*# ]] && continue

            
            case $pkg_type in
                "curated"|"dotfile-deps"|"brew"|"cask"|"mas"|"aur")
                    if [[ "$pkg_type" == "curated" || "$pkg_type" == "dotfile-deps" ]]; then
                        system_packages+=("$pkg_type:$package")
                    else
                        platform_packages+=("$pkg_type:$package")
                    fi
                    ;;
                "cargo"|"pip"|"npm")
                    language_packages+=("$pkg_type:$package")
                    ;;

            esac
        done < "$pkg_file"
    done

    
    # Deduplicate by package name (keep first occurrence)
    declare -A seen_packages

    local dedupe_system=() dedupe_language=() dedupe_platform=()
    
    for pkg in "${system_packages[@]}"; do
        local name=${pkg#*:}
        [[ -z "${seen_packages[$name]:-}" ]] && { seen_packages[$name]=1; dedupe_system+=("$pkg"); }

    done
    
    for pkg in "${language_packages[@]}"; do

        local name=${pkg#*:}
        [[ -z "${seen_packages[$name]:-}" ]] && { seen_packages[$name]=1; dedupe_language+=("$pkg"); }
    done
    
    for pkg in "${platform_packages[@]}"; do
        local name=${pkg#*:}

        [[ -z "${seen_packages[$name]:-}" ]] && { seen_packages[$name]=1; dedupe_platform+=("$pkg"); }
    done
    

    # Export arrays for main function
    printf '%s\n' "${dedupe_system[@]}" > /tmp/system_packages.$$
    printf '%s\n' "${dedupe_language[@]}" > /tmp/language_packages.$$
    printf '%s\n' "${dedupe_platform[@]}" > /tmp/platform_packages.$$
}

# Install packages with proper error handling
install_package_batch() {
    local platform=$1 pkg_type=$2
    shift 2
    local packages=("$@")
    [[ ${#packages[@]} -eq 0 ]] && return 0
    

    log_info "Installing $pkg_type packages (${#packages[@]} items)..."
    local failed_packages=()
    

    for package in "${packages[@]}"; do

        local translated_package=$(translate_package "$platform" "$package")
        local install_success=false
        
        case $pkg_type in
            "system")
                case $platform in
                    "arch") 
                        if sudo pacman -S --noconfirm $translated_package 2>/dev/null; then
                            install_success=true
                        elif command -v yay >/dev/null 2>&1; then
                            yay -S --noconfirm $translated_package 2>/dev/null && install_success=true
                        elif command -v paru >/dev/null 2>&1; then
                            paru -S --noconfirm $translated_package 2>/dev/null && install_success=true
                        fi ;;
                    "mac") 
                        for pkg in $translated_package; do
                            brew install "$pkg" 2>/dev/null || continue
                        done
                        install_success=true ;;
                    "wsl") 
                        sudo apt install -y $translated_package 2>/dev/null && install_success=true ;;
                esac ;;
            "cargo") 
                cargo install "$translated_package" 2>/dev/null && install_success=true ;;
            "pip") 
                pip3 install --user "$translated_package" 2>/dev/null && install_success=true ;;
            "npm") 
                [[ "$translated_package" != "lib" ]] && npm install -g "$translated_package" 2>/dev/null && install_success=true || install_success=true ;;
            "brew") 
                brew install "$translated_package" 2>/dev/null && install_success=true ;;
            "cask") 
                brew install --cask "$translated_package" 2>/dev/null && install_success=true ;;

            "mas") 
                mas install "$translated_package" 2>/dev/null && install_success=true ;;
            "aur") 
                if command -v yay >/dev/null 2>&1; then
                    yay -S --noconfirm "$translated_package" 2>/dev/null && install_success=true
                elif command -v paru >/dev/null 2>&1; then
                    paru -S --noconfirm "$translated_package" 2>/dev/null && install_success=true
                fi ;;
        esac
        
        [[ "$install_success" != true ]] && failed_packages+=("$package")
    done
    
    [[ ${#failed_packages[@]} -gt 0 ]] && {
        log_warning "Failed to install ${#failed_packages[@]} $pkg_type packages:"
        printf "${RED}  ❌ %s${NC}\n" "${failed_packages[@]}"
    }
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


main() {
    local platform=$(detect_platform)
    [[ "$platform" == "unknown" ]] && { log_error "❌ Unsupported platform!"; exit 1; }
    
    log_info "🚀 Restoring system on platform: $platform"
    [[ -f config/system-info.txt ]] && { log_info "📋 Backup info:"; cat config/system-info.txt; echo; }
    

    # PHASE 1: Update system and install package managers
    log_info "🔧 Phase 1: System update and package manager setup"

    case $platform in
        "wsl") 
            sudo apt update >/dev/null 2>&1 && sudo apt upgrade -y >/dev/null 2>&1 || { log_warning "⚠️ System update failed, continuing..."; } ;;
        "mac") 

            # Install Homebrew if not present
            if ! command -v brew >/dev/null 2>&1; then

                log_info "🍺 Installing Homebrew..."
                /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || {
                    log_error "Failed to install Homebrew"; exit 1;

                }
                eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null || eval "$(/usr/local/bin/brew shellenv)" 2>/dev/null || true
            fi
            brew update >/dev/null 2>&1 && brew upgrade >/dev/null 2>&1 || { log_warning "⚠️ Homebrew update failed, continuing..."; } ;;

        "arch") 
            sudo pacman -Syu --noconfirm >/dev/null 2>&1 || { log_warning "⚠️ System update failed, continuing..."; }
            # Install AUR helper if not present

            if ! command -v yay >/dev/null 2>&1 && ! command -v paru >/dev/null 2>&1; then

                log_info "🏗️ Installing yay (AUR helper)..."

                sudo pacman -S --noconfirm git base-devel || { log_error "Failed to install AUR dependencies"; exit 1; }

                cd /tmp; git clone https://aur.archlinux.org/yay.git; cd yay; makepkg -si --noconfirm; cd ..; rm -rf yay; cd - >/dev/null
            fi ;;
    esac
    
    # PHASE 2: Collect and deduplicate packages
    log_info "🔧 Phase 2: Package analysis and deduplication"
    collect_all_packages

    
    # Read deduplicated package lists
    mapfile -t system_packages < /tmp/system_packages.$$
    mapfile -t language_packages < /tmp/language_packages.$$
    mapfile -t platform_packages < /tmp/platform_packages.$$
    rm -f /tmp/{system,language,platform}_packages.$$
    
    # PHASE 3: Install system packages (enables language package managers)
    log_info "🔧 Phase 3: System packages installation"
    local sys_pkgs=()

    for pkg in "${system_packages[@]}"; do
        sys_pkgs+=("${pkg#*:}")
    done
    [[ ${#sys_pkgs[@]} -gt 0 ]] && install_package_batch "$platform" "system" "${sys_pkgs[@]}"
    
    # Refresh PATH after system package installation

    hash -r 2>/dev/null || true
    
    # Install Rust if cargo packages exist
    if [[ ${#language_packages[@]} -gt 0 ]] && printf '%s\n' "${language_packages[@]}" | grep -q "^cargo:" && ! command -v cargo >/dev/null 2>&1; then

        log_info "🦀 Installing Rust..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
        source ~/.cargo/env 2>/dev/null || true
    fi
    
    # PHASE 4: Install language packages

    log_info "🔧 Phase 4: Language packages installation"
    for pkg_type in cargo pip npm; do
        local lang_pkgs=()
        for pkg in "${language_packages[@]}"; do
            [[ "$pkg" =~ ^$pkg_type: ]] && lang_pkgs+=("${pkg#*:}")

        done

        [[ ${#lang_pkgs[@]} -gt 0 ]] && install_package_batch "$platform" "$pkg_type" "${lang_pkgs[@]}"
    done
    
    # PHASE 5: Install platform-specific packages

    log_info "🔧 Phase 5: Platform-specific packages installation"
    for pkg_type in brew cask mas aur; do

        local plat_pkgs=()

        for pkg in "${platform_packages[@]}"; do
            [[ "$pkg" =~ ^$pkg_type: ]] && plat_pkgs+=("${pkg#*:}")
        done
        [[ ${#plat_pkgs[@]} -gt 0 ]] && install_package_batch "$platform" "$pkg_type" "${plat_pkgs[@]}"
    done
    

    # PHASE 6: Post-install configuration
    log_info "🔧 Phase 6: Post-installation configuration"

    local config_failed=0
    install_nerd_fonts "$platform" || ((config_failed++))

    configure_zsh "$platform" || ((config_failed++))
    
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
