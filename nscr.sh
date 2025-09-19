set -e

check_commands() {
    local missing_cmds=()
    for cmd in curl git makepkg vercmp; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_cmds+=("$cmd")
        fi
    done

    if [ ${#missing_cmds[@]} -gt 0 ]; then
        echo "[NSCR] The following commands are not available: ${missing_cmds[@]}"
        echo "[NSCR] Please install their respective packages and try again."
        exit 1
    fi
}

get_current_version() {
    local pkg=$1
    local current_version

    current_version=$(pacman -Qi "$pkg" 2>/dev/null | awk -v pkg="$pkg" '
        $1 == "Name" && $3 == pkg { valid=1 }
        valid && $1 == "Version" { print $3; exit }
    ')

    echo "$current_version"
}

clone_and_build() {
    local pkg=$1
    local dir="/tmp/nscr/$pkg"
    local cleanup_done=0

    if [ -d "$dir" ]; then
        echo "[NSCR] Error: Directory $dir already exists. Remove it before proceeding."
        exit 1
    fi

    echo "[NSCR] Looking for ($pkg) in system"
    current_version=$(get_current_version "$pkg")

    if [[ -n "$current_version" ]]; then
        latest_version=$(curl -s "https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h=$pkg" | grep -E '^pkgver=' | cut -d'=' -f2)
        version_comparison=$(vercmp "$current_version" "$latest_version")
        if [[ "$version_comparison" -ge 0 ]]; then
            echo "[NSCR] You already have the latest version ($current_version)"
            if [ ! -f "$HOME/.local/share/nscrInstalledPackages.txt" ]; then touch "$HOME/.local/share/nscrInstalledPackages.txt"; fi
            if ! grep -q "^$pkg$" "$HOME/.local/share/nscrInstalledPackages.txt"; then save_installed_packages; fi

            exit 0
        fi
    fi

    echo "[NSCR] Downloading $pkg:$latest_version instructions..."
    git clone "https://aur.archlinux.org/$pkg.git" "$dir" &>/dev/null || { echo "[NSCR] $pkg:$latest_version instructions download failed"; exit 1; }

    trap 'if [ $cleanup_done -eq 0 ]; then rm -rf "$dir"; echo "[NSCR] Cleaned up temporary files."; cleanup_done=1; fi' EXIT INT TERM

    pushd "$dir" > /dev/null || { echo "[NSCR] Failed to enter directory $dir"; exit 1; }

    echo "[NSCR] Proceeding security check..."
    security_check "$pkg"

    echo "[NSCR] Verifying sources"
    makepkg --verifysource || { echo "[NSCR] Error verifying sources"; exit 1; }
    makepkg -si || { echo "[NSCR] Error installing package"; exit 1; }

    popd > /dev/null

    save_installed_packages
}

security_check() {
    suspicious=$(grep -En "curl|wget|base64|eval|bash -c|perl -e|python -c|openssl|nc -e|rm -rf /|git clone" PKGBUILD "$1.install" || true)

    if [[ -n "$suspicious" ]]; then
        echo "[NSCR] Warning: Suspicious PKGBUILD lines found:"
        echo "$suspicious"
        read -p "[NSCR] Do you want to continue despite the warnings? Type 'continue' to proceed: " user_input
        if [[ "$user_input" != "continue" ]]; then
            echo "[NSCR] Exiting due to security concerns."
            exit 1
        fi
    else
        echo "[NSCR] Security check passed."
    fi
}

save_installed_packages() {
    echo "$PKG" >> "$HOME/.local/share/nscrInstalledPackages.txt"
    echo "[NSCR] $PKG has been added to the list of installed packages."
}


update_installed_packages() {
    if [ -f "$HOME/.local/share/nscrInstalledPackages.txt" ]; then
        while IFS= read -r pkg; do
            echo "[NSCR] Updating package $pkg..."
            clone_and_build "$pkg"
        done < "$HOME/.local/share/nscrInstalledPackages.txt"
    else
        echo "[NSCR] No installed packages found"
    fi
}

check_commands

read -p "[NSCR] (1) Install new package, (2) Update installed packages: " action_choice

if [ "$action_choice" == "2" ]; then
    update_installed_packages
    exit 0
fi

read -p "[NSCR] Enter the package name: " PKG

clone_and_build "$PKG"

echo "[NSCR] $PKG has been installed."
