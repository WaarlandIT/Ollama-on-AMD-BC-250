#!/bin/bash
# =============================================================================
# BC-250 / Cyan Skillfish Setup Script
# Ubuntu 26.04 LTS "Resolute Raccoon"
# Mesa Vulkan · Xanmod Kernel · Ollama · Cyan Skillfish Governor · Sensors
# =============================================================================
# Run as a regular user with sudo privileges:
#   chmod +x bc250-setup.sh && ./bc250-setup.sh
# =============================================================================

set -euo pipefail

# --- Colours -----------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Colour

# --- Helpers -----------------------------------------------------------------
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

step() {
    echo ""
    echo -e "${BOLD}${CYAN}============================================================${NC}"
    echo -e "${BOLD}${CYAN}  $*${NC}"
    echo -e "${BOLD}${CYAN}============================================================${NC}"
}

confirm() {
    local prompt="$1"
    local response
    read -rp "$(echo -e "${YELLOW}[?]${NC} ${prompt} [y/N] ")" response
    [[ "${response,,}" == "y" ]]
}

require_root() {
    if [[ $EUID -eq 0 ]]; then
        die "Do not run this script as root. Run as a regular user with sudo privileges."
    fi
    sudo -v || die "sudo privileges required."
    # Keep sudo alive throughout the script
    ( while true; do sudo -n true; sleep 50; done ) &
    SUDO_KEEPALIVE_PID=$!
    trap 'kill $SUDO_KEEPALIVE_PID 2>/dev/null' EXIT
}

check_ubuntu() {
    if ! grep -q 'Ubuntu' /etc/os-release 2>/dev/null; then
        warn "This script is designed for Ubuntu 26.04 LTS. Detected OS may differ."
        confirm "Continue anyway?" || exit 0
    fi
    local codename
    codename=$(lsb_release -sc 2>/dev/null || echo "unknown")
    if [[ "$codename" != "resolute" ]]; then
        warn "Expected Ubuntu 26.04 (resolute), detected: ${codename}"
        confirm "Continue anyway?" || exit 0
    fi
}

# =============================================================================
# STEP 1 — System update
# =============================================================================
step "1/8 — System Update"
info "Updating package lists and upgrading existing packages..."
sudo apt-get update -qq
sudo apt-get upgrade -y
success "System is up to date."

# =============================================================================
# STEP 2 — Archive keyring
# =============================================================================
step "2/8 — Archive Keyring"
if [[ -f /usr/share/keyrings/debian-archive-keyring.gpg ]]; then
    success "debian-archive-keyring.gpg already present."
else
    info "Installing debian-archive-keyring..."
    sudo apt-get install -y debian-archive-keyring
    success "Keyring installed."
fi

# =============================================================================
# STEP 3 — Mesa Vulkan drivers
# =============================================================================
step "3/8 — Mesa Vulkan Drivers"
info "Installing mesa-vulkan-drivers, libgl1-mesa-dri, mesa-utils..."
sudo apt-get install -y -t experimental \
    mesa-vulkan-drivers \
    libgl1-mesa-dri \
    mesa-utils
success "Mesa Vulkan drivers installed."

info "Verifying OpenGL version..."
if command -v glxinfo &>/dev/null; then
    glxinfo 2>/dev/null | grep "OpenGL version" || warn "glxinfo returned no OpenGL version (headless/no display?)"
else
    warn "glxinfo not available — skipping OpenGL check."
fi

# =============================================================================
# STEP 4 — Xanmod Kernel
# =============================================================================
step "4/8 — Xanmod Kernel"

# Check AVX2 support
if ! grep -qm1 'avx2' /proc/cpuinfo; then
    die "Your CPU does not support AVX2. The x64v3 Xanmod kernel requires AVX2. Aborting."
fi
success "AVX2 supported — x64v3 kernel is compatible."

info "Creating /etc/apt/keyrings directory..."
sudo mkdir -p /etc/apt/keyrings

info "Importing Xanmod GPG key..."
wget -qO - https://dl.xanmod.org/archive.key \
    | sudo gpg --dearmor -vo /etc/apt/keyrings/xanmod-archive-keyring.gpg
success "Xanmod GPG key imported."

info "Adding Xanmod repository..."
echo "deb [signed-by=/etc/apt/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org $(lsb_release -sc) main" \
    | sudo tee /etc/apt/sources.list.d/xanmod-release.list > /dev/null
success "Xanmod repository added."

info "Updating package lists and installing Xanmod LTS kernel..."
sudo apt-get update -qq
sudo apt-get install -y linux-xanmod-lts-x64v3
success "Xanmod LTS kernel installed."

info "Updating GRUB..."
sudo update-grub
success "GRUB updated."

# =============================================================================
# STEP 5 — Ollama + Vulkan
# =============================================================================
step "5/8 — Ollama + Vulkan Setup"

info "Installing Ollama..."
curl -fsSL https://ollama.com/install.sh | sh
success "Ollama installed."

info "Configuring Ollama systemd override (Vulkan backend + memory settings)..."
sudo mkdir -p /etc/systemd/system/ollama.service.d
sudo tee /etc/systemd/system/ollama.service.d/override.conf > /dev/null <<'EOF'
[Service]
Environment=OLLAMA_VULKAN=1
Environment=OLLAMA_KEEP_ALIVE=30m
Environment=OLLAMA_MAX_LOADED_MODELS=1
Environment=OLLAMA_FLASH_ATTENTION=1
Environment=OLLAMA_GPU_OVERHEAD=0
Environment=OLLAMA_CONTEXT_LENGTH=16384
Environment=OLLAMA_MAX_QUEUE=4
OOMScoreAdjust=-1000
EOF
sudo systemctl daemon-reload
sudo systemctl restart ollama
success "Ollama Vulkan override applied."

info "Applying TTM pages_limit fix (runtime)..."
echo 4194304 | sudo tee /sys/module/ttm/parameters/pages_limit > /dev/null
echo 4194304 | sudo tee /sys/module/ttm/parameters/page_pool_size > /dev/null
success "TTM pages_limit set to 4194304 (16 GiB)."

info "Making TTM fix persistent across reboots..."
echo "options ttm pages_limit=4194304 page_pool_size=4194304" \
    | sudo tee /etc/modprobe.d/ttm-gpu-memory.conf > /dev/null
printf "w /sys/module/ttm/parameters/pages_limit - - - - 4194304\nw /sys/module/ttm/parameters/page_pool_size - - - - 4194304\n" \
    | sudo tee /etc/tmpfiles.d/gpu-ttm-memory.conf > /dev/null
success "TTM fix will persist after reboot."

info "Setting up 16 GB swap file..."
if swapon --show | grep -q '/swapfile'; then
    warn "/swapfile already active — skipping swap creation."
elif [[ -f /swapfile ]]; then
    warn "/swapfile exists but is not active — enabling it."
    sudo swapon -p 10 /swapfile
else
    sudo dd if=/dev/zero of=/swapfile bs=1M count=16384 status=progress
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon -p 10 /swapfile
    if ! grep -q '/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw,pri=10 0 0' | sudo tee -a /etc/fstab > /dev/null
    fi
    success "16 GB swap file created and enabled."
fi

info "Locking CPU governor to performance (runtime)..."
echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor > /dev/null
info "Making CPU governor persistent..."
echo 'w /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor - - - - performance' \
    | sudo tee /etc/tmpfiles.d/cpu-governor.conf > /dev/null
success "CPU governor set to performance."

# =============================================================================
# STEP 6 — Cyan Skillfish Governor
# =============================================================================
step "6/8 — Cyan Skillfish Governor"

GOVERNOR_DEB="cyan-skillfish-governor_0.1.3-1_amd64.deb"
GOVERNOR_URL="https://github.com/Magnap/cyan-skillfish-governor/releases/download/v0.1.3/${GOVERNOR_DEB}"

info "Downloading Cyan Skillfish Governor..."
wget -q --show-progress -O "/tmp/${GOVERNOR_DEB}" "${GOVERNOR_URL}"
success "Downloaded ${GOVERNOR_DEB}."

info "Installing package..."
sudo dpkg -i "/tmp/${GOVERNOR_DEB}"
rm -f "/tmp/${GOVERNOR_DEB}"
success "Cyan Skillfish Governor installed."

info "Enabling and starting service..."
sudo systemctl enable --now cyan-skillfish-governor.service
success "cyan-skillfish-governor.service enabled."

info "Verifying governor service..."
if systemctl is-active --quiet cyan-skillfish-governor.service; then
    success "Service is running."
else
    warn "Service does not appear to be running. Check: systemctl status cyan-skillfish-governor"
fi

# =============================================================================
# STEP 7 — Hardware Sensors (lm-sensors / nct6683)
# =============================================================================
step "7/8 — Hardware Sensors"

info "Installing lm-sensors..."
sudo apt-get install -y lm-sensors
success "lm-sensors installed."

info "Configuring nct6683 module to load at boot..."
echo 'nct6683' | sudo tee /etc/modules-load.d/nct6683.conf > /dev/null
echo 'options nct6683 force=true' | sudo tee /etc/modprobe.d/sensors.conf > /dev/null
success "nct6683 boot configuration written."

info "Loading nct6683 module now..."
if sudo modprobe nct6683 force=true 2>/dev/null; then
    success "nct6683 module loaded."
    sensors
else
    warn "nct6683 module failed to load — may require a reboot with the new kernel."
fi

# =============================================================================
# STEP 8 — Vulkan Tools
# =============================================================================
step "8/8 — Vulkan Tools"

info "Installing vulkan-tools..."
sudo apt-get install -y vulkan-tools
success "vulkan-tools installed."

info "Running vulkaninfo --summary..."
if vulkaninfo --summary 2>/dev/null; then
    success "Vulkan is working."
else
    warn "vulkaninfo returned an error — Vulkan may not be available until after reboot."
fi

# =============================================================================
# DONE
# =============================================================================
echo ""
echo -e "${BOLD}${GREEN}============================================================${NC}"
echo -e "${BOLD}${GREEN}  All steps completed successfully!${NC}"
echo -e "${BOLD}${GREEN}============================================================${NC}"
echo ""
echo -e "  ${BOLD}Installed:${NC}"
echo -e "    ${GREEN}✓${NC} Mesa Vulkan drivers (experimental)"
echo -e "    ${GREEN}✓${NC} Xanmod LTS kernel (x64v3)"
echo -e "    ${GREEN}✓${NC} Ollama with Vulkan backend"
echo -e "    ${GREEN}✓${NC} TTM pages_limit tuning (16 GiB GTT)"
echo -e "    ${GREEN}✓${NC} 16 GB NVMe swap"
echo -e "    ${GREEN}✓${NC} CPU performance governor"
echo -e "    ${GREEN}✓${NC} Cyan Skillfish Governor"
echo -e "    ${GREEN}✓${NC} lm-sensors + nct6683"
echo -e "    ${GREEN}✓${NC} Vulkan tools"
echo ""
echo -e "  ${BOLD}${YELLOW}A reboot is required to load the Xanmod kernel.${NC}"
echo -e "  After rebooting, verify Ollama with:"
echo -e "    ${CYAN}sudo journalctl -u ollama -n 20 | grep total${NC}"
echo -e "  Pull your first model with:"
echo -e "    ${CYAN}ollama pull qwen2.5:7b${NC}"
echo ""

confirm "Reboot now?" && sudo reboot
