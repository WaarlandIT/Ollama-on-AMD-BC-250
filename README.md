# Ubuntu 26.04 LTS "Resolute Raccoon" Installation Manual
## Experimental Repo, Mesa Vulkan, Xanmod Kernel, Ollama & Hardware Tools

---

## 1. Configure APT Sources (DEB822 Format)

Debian's modern package source format uses `.sources` files instead of the old `.list` one-liners. Create the following files in `/etc/apt/sources.list.d/`.

### 1.1 Debian Experimental Repository

Create `/etc/apt/sources.list.d/debian-experimental.sources`:

```
Types: deb
URIs: http://deb.debian.org/debian
Suites: experimental
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
```

> **Note:** `experimental` has no base packages of its own — it only provides upgrades on top of an existing suite (stable/bookworm). Make sure you also have a stable source configured.

### 1.2 Archive Keyring

The `debian-archive-keyring.gpg` file is already present on any working Ubuntu system. Verify it exists:

```bash
ls /usr/share/keyrings/debian-archive-keyring.gpg
```

If it is missing, install it via apt:

```bash
sudo apt install debian-archive-keyring
```



---

## 2. Update Package Lists

After configuring sources, always update:

```bash
sudo apt update
```

---

## 3. Mesa Vulkan Drivers (from Experimental)

Install the latest Mesa Vulkan and OpenGL drivers from the experimental repository:

```bash
sudo apt install -t experimental mesa-vulkan-drivers libgl1-mesa-dri
```

Verify the OpenGL version (requires `mesa-utils`):

```bash
sudo apt install mesa-utils
glxinfo | grep "OpenGL version"
```

---

## 4. Xanmod Kernel

Xanmod is a custom Linux kernel with performance patches. It requires adding a third-party repository.

### 4.1 Add the Xanmod Repository Key

```bash
wget -qO - https://dl.xanmod.org/archive.key | sudo gpg --dearmor -vo /etc/apt/keyrings/xanmod-archive-keyring.gpg
```

### 4.2 Add the Repository Source

```bash
echo "deb [signed-by=/etc/apt/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org $(lsb_release -sc) main" \
  | sudo tee /etc/apt/sources.list.d/xanmod-release.list
```

### 4.3 Update and Install

```bash
sudo apt update
sudo apt install linux-xanmod-lts-x64v3
```

> `x64v3` targets modern x86-64 CPUs (AVX2 support required). Run `grep -m1 avx2 /proc/cpuinfo` to confirm your CPU supports it.

### 4.4 Update GRUB

After kernel installation, update GRUB to register the new kernel:

```bash
sudo nano /etc/default/grub   # Adjust GRUB_DEFAULT or other settings if needed
sudo update-grub
```


---

## 5. Ollama + Vulkan Setup

Ollama provides a local LLM runtime. On AMD BC-250 / Cyan Skillfish hardware (GFX1013), ROCm is not supported — Vulkan is the only viable GPU compute path.

### 5.1 Install Ollama

```bash
curl -fsSL https://ollama.com/install.sh | sh
```

### 5.2 Enable Vulkan Backend

Vulkan inference is disabled by default. Create a systemd drop-in to enable it and configure memory behaviour:

```bash
sudo mkdir -p /etc/systemd/system/ollama.service.d
cat <<EOF | sudo tee /etc/systemd/system/ollama.service.d/override.conf
[Service]
Environment=OLLAMA_VULKAN=1
Environment=OLLAMA_KEEP_ALIVE=30m
Environment=OLLAMA_MAX_LOADED_MODELS=1
Environment=OLLAMA_FLASH_ATTENTION=1
Environment=OLLAMA_GPU_OVERHEAD=0
Environment=OLLAMA_CONTEXT_LENGTH=16384
Environment=OLLAMA_MAX_QUEUE=4
Environment=OLLAMA_HOST=0.0.0.0
OOMScoreAdjust=-1000
EOF
sudo systemctl daemon-reload && sudo systemctl restart ollama
```

> `OOMScoreAdjust=-1000` protects Ollama from the OOM killer — the model process must survive memory pressure. ROCm will crash during startup on this hardware; this is expected and harmless. Ollama catches it and falls back to Vulkan automatically.

### 5.3 Tune TTM pages_limit (unlocks large models)

Without this fix, large models (14B+) load correctly but produce HTTP 500 errors during inference. The kernel TTM memory manager independently caps GPU memory allocations at ~7.4 GiB by default.

Apply the fix immediately (runtime):

```bash
echo 4194304 | sudo tee /sys/module/ttm/parameters/pages_limit
echo 4194304 | sudo tee /sys/module/ttm/parameters/page_pool_size
```

Make it persistent across reboots:

```bash
echo "options ttm pages_limit=4194304 page_pool_size=4194304" | \
  sudo tee /etc/modprobe.d/ttm-gpu-memory.conf

printf "w /sys/module/ttm/parameters/pages_limit - - - - 4194304\n\
w /sys/module/ttm/parameters/page_pool_size - - - - 4194304\n" | \
  sudo tee /etc/tmpfiles.d/gpu-ttm-memory.conf
```

> **Note on `amdgpu.gttsize`:** This kernel parameter is no longer needed. With `ttm.pages_limit=4194304` alone, GTT allocates the full 16 GiB. If you have `amdgpu.gttsize` in your kernel command line from older guides, remove it — it was actually limiting the allocation.

### 5.4 Context Window

Ollama allocates KV cache based on the model's declared context window. Without a cap, large models request more KV cache than can fit in unified memory, causing TTM fragmentation, OOM kills, or deadlocks.

The `OLLAMA_CONTEXT_LENGTH=16384` set in §5.2 caps all inference to 16K context by default. Individual requests can override this per-call with `{"options": {"num_ctx": 65536}}` when using smaller models that support it.

### 5.5 Swap — NVMe-backed Safety Net

With large models consuming 10–12 GB on a 16 GB system, NVMe swap is essential for surviving inference peaks and model load/unload transitions.

```bash
# Create 16 GB swap file
# Use dd instead of fallocate if on btrfs
sudo dd if=/dev/zero of=/swapfile bs=1M count=16384 status=progress
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon -p 10 /swapfile

# Make permanent
echo '/swapfile none swap sw,pri=10 0 0' | sudo tee -a /etc/fstab
```

> In steady state, swap usage is typically only a few hundred MB — the model runs in RAM. Swap catches transient spikes during model load/unload transitions.

### 5.6 CPU Governor — Lock to `performance`

The default `schedutil` governor down-clocks during idle, causing 50–100ms latency spikes at the start of inference. Lock all cores to full speed:

```bash
# Runtime (immediate)
echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor

# Persistent across reboots
echo 'w /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor - - - - performance' | \
  sudo tee /etc/tmpfiles.d/cpu-governor.conf
```

### 5.7 Disable GUI (Optional — saves ~1 GB RAM)

If running headless, switching to multi-user mode frees roughly 1 GB of memory:

```bash
sudo systemctl set-default multi-user.target && sudo reboot
```

### 5.8 Verify

After rebooting, confirm Ollama is using the GPU and that memory is correctly allocated:

```bash
sudo journalctl -u ollama -n 20 | grep total
# Expected: total="11.1 GiB" available="11.1 GiB"

free -h
# Check that swap is active

vulkaninfo --summary
# Should show your AMD GPU with Vulkan support
```

### 5.9 Pull and Run a Model

```bash
ollama pull qwen2.5:7b
ollama run qwen2.5:7b
```

---

## 6. Cyan Skillfish Governor (AMD GPU Power Management)

The `cyan-skillfish-governor` is a user-space power governor for AMD integrated GPUs (Cyan Skillfish / RDNA2 iGPU).

### 6.1 Download the Package

```bash
wget https://github.com/Magnap/cyan-skillfish-governor/releases/download/v0.1.3/cyan-skillfish-governor_0.1.3-1_amd64.deb
```

### 6.2 Install

```bash
sudo dpkg -i cyan-skillfish-governor_0.1.3-1_amd64.deb
```

### 6.3 Enable and Start the Service

```bash
sudo systemctl enable --now cyan-skillfish-governor.service
```

### 6.4 Verify

Check service status:

```bash
systemctl status cyan-skillfish-governor
```

Check GPU clock states:

```bash
cat /sys/class/drm/card1/device/pp_dpm_sclk
```

---

## 7. Hardware Sensors (lm-sensors / nct6683)

### 7.1 Install lm-sensors

```bash
sudo apt install lm-sensors
```

### 7.2 Load the nct6683 Module at Boot

```bash
echo 'nct6683' | sudo tee /etc/modules-load.d/nct6683.conf
echo 'options nct6683 force=true' | sudo tee /etc/modprobe.d/sensors.conf
```

### 7.3 Load the Module Immediately (without rebooting)

```bash
sudo modprobe nct6683 force=true
```

### 7.4 Read Sensor Data

```bash
sensors
```

---

## 8. Vulkan Tools

### 8.1 Install

```bash
sudo apt install vulkan-tools
```

### 8.2 Verify Vulkan

Full Vulkan device info:

```bash
vulkaninfo
```

Compact summary:

```bash
vulkaninfo --summary
```

---

## Summary of Installed Components

| Component | Package / Source |
|---|---|
| Mesa Vulkan drivers | `mesa-vulkan-drivers`, `libgl1-mesa-dri` (experimental) |
| Mesa utilities | `mesa-utils` |
| Xanmod LTS kernel | `linux-xanmod-lts-x64v3` (xanmod repo) |
| Ollama (Vulkan backend) | `install.sh` (ollama.com) |
| AMD GPU governor | `cyan-skillfish-governor_0.1.3-1_amd64.deb` (GitHub) |
| Hardware sensors | `lm-sensors` + `nct6683` module |
| Vulkan tools | `vulkan-tools` |

---

## 9. Recommended Models for Vulkan Inference

All models below are confirmed working on AMD GFX1013 (Cyan Skillfish) via Vulkan. ROCm is not supported on this hardware — Vulkan is the only GPU compute path. All inference runs 100% on GPU after the TTM tuning in §5.3.

> Benchmarks from the [bc250 project](https://github.com/akandr/bc250) — AMD BC-250 (Zen 2, 16 GB GDDR6 unified, RDNA 1.5, 16.5 GiB Vulkan after tuning).

### 9.1 Recommended by Use Case

| Use Case | Model | tok/s | Max Context | Notes |
|---|---|---|---|---|
| **General AI — primary** | `qwen3.5-35b-a3b-iq2m` | 38 | 16K | MoE: 35B knowledge, only 3B active per token. Best reasoning. |
| **Long context / vision** | `qwen3.5:9b` | 32 | 65K | Multimodal (images). Best for documents and photos. |
| **Long context (14B)** | `phi4:14b` | 29 | 40K | Best 14B model for extended context on this hardware. |
| **Fast general use** | `qwen2.5:7b` | 56 | 64K | 2× faster than 14B, still 64K context. |
| **Code generation** | `qwen2.5-coder:7b` | 56 | 64K | Same speed as base 7B, code-specialised. |
| **Maximum speed** | `qwen2.5:3b` | 104 | 64K | 4× faster than 14B. Best for simple/fast tasks. |

### 9.2 Full Compatibility Table

| Model | Params | Quant | tok/s | Max Context | VRAM | Status |
|---|---|---|---|---|---|---|
| `qwen3.5-35b-a3b-iq2m` | 35B/3B active | UD-IQ2_M | **38** | 16K | 12.3 GiB | ✅ Primary — MoE |
| `qwen3.5:9b` | 9.7B | Q4_K_M | **32** | 65K | 8.6 GiB | ✅ Best context + vision |
| `qwen2.5:3b` | 3.1B | Q4_K_M | **104** | 64K | 3.4 GiB | ✅ Fastest |
| `qwen2.5:7b` | 7.6B | Q4_K_M | **56** | 64K | 6.5 GiB | ✅ Great quality/speed |
| `qwen2.5-coder:7b` | 7.6B | Q4_K_M | **56** | 64K | 6.4 GiB | ✅ Code-focused |
| `llama3.1:8b` | 8.0B | Q4_K_M | **52** | 48K | 11.0 GiB | ✅ Fast 8B |
| `qwen3:8b` | 8.2B | Q4_K_M | **44** | 64K | 9.8 GiB | ✅ Thinking mode |
| `gemma2:9b` | 9.2B | Q4_0 | **38** | 48K | 9.2 GiB | ✅ Works after GTT fix |
| `phi4:14b` | 14.7B | Q4_K_M | **29** | 40K | 11.8 GiB | ✅ Best 14B context |
| `qwen3:14b` | 14.8B | Q4_K_M | **27** | 24K | 13.5 GiB | ✅ Previous primary |
| `mistral-nemo:12b` | 12.2B | Q4_0 | **34** | 24K | 10.8 GiB | ⚠️ 32K+ deadlocks |
| `qwen3.5-27b` (dense) | 26.9B | IQ2_M | 0 | — | 13.5 GiB | ❌ Non-functional — no matrix cores |

### 9.3 Why Dense 27B+ Models Fail

The GFX1013 GPU has no matrix/tensor cores. Every model forward pass uses general-purpose shader cores for matrix multiplication. A dense 27B model requires all 27 billion parameters to be processed for every single token — without hardware acceleration this results in effectively zero throughput (0 tokens in 5+ minutes).

The 35B MoE model works because only ~3B parameters activate per token despite the full 35B being stored in memory. The router selects which experts fire per token, making the effective compute cost equivalent to a 3B dense model.

### 9.4 Pulling Models

```bash
# Recommended starting point — fast and capable
ollama pull qwen2.5:7b

# Primary model (requires custom GGUF — see bc250 guide for Modelfile)
# ollama create qwen3.5-35b-a3b-iq2m -f Modelfile

# High-context and vision
ollama pull qwen3.5:9b

# Code assistant
ollama pull qwen2.5-coder:7b

# Check what is loaded
ollama ps
```

### 9.5 Context Size vs Memory (qwen3:14b reference)

Useful reference for understanding the memory/context tradeoff on 16 GB unified memory:

| Context | RAM Used | Speed | Status |
|---|---|---|---|
| 8K | ~9.5 GB | ~27 tok/s | ✅ Very safe |
| 16K | ~11.1 GB | ~27 tok/s | ✅ Comfortable |
| 24K | ~14.4 GB | ~27 tok/s | ✅ Maximum for 14B |
| 28K | ~14.2 GB | timeout | ❌ Deadlocks |
| 40K | ~16.0 GB | — | 💀 TTM fragmentation |

> Speed stays constant as context grows — degradation only occurs when the context is actually *filled* with tokens, not just allocated. The ceiling is purely a memory constraint: weights + KV cache + OS must all fit in 16.5 GiB.
