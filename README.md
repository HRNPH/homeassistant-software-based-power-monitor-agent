# Proxmox Power Monitor Agent for Home Assistant

A one-shot setup script that deploys a systemd service on your Proxmox host to push real-time CPU (and optional NVIDIA GPU) power draw to [Home Assistant](https://www.home-assistant.io/) via the REST API.

## What It Does

1. **Checks and installs dependencies** (`curl`, `sed`, `stdbuf`, `xargs`, `turbostat` via `linux-cpupower`, MSR kernel module).
2. **Walks you through configuration** — HA address, access token, entity names, GPU toggle.
3. **Generates a runtime agent** at `/usr/local/bin/proxmox_power_agent.sh` that polls `turbostat` (CPU) and optionally `nvidia-smi` (GPU) every second and POSTs readings to the Home Assistant REST API.
4. **Installs a systemd service** (`proxmox-power.service`) that starts on boot and auto-restarts on failure.

## Requirements

- **Proxmox VE host** (Debian-based, using `apt` as the package manager — run as root or with sudo)
- **Home Assistant** instance accessible over the network
- **Intel CPU** with RAPL support (required by `turbostat` for `PkgWatt` readings)
- **NVIDIA GPU** (optional — auto-detected if `nvidia-smi` is present)

## Quick Start

```bash
# Clone and run as root
git clone https://github.com/HRNPH/homeassistant-software-based-power-monitor-agent.git
cd homeassistant-software-based-power-monitor-agent
sudo bash setup_power_agent.sh
```

The script is interactive — it will prompt you for:

| Prompt | Description | Default |
|--------|-------------|---------|
| Home Assistant IP/Host | Address of your HA instance | — |
| Home Assistant Port | Port number | `8123` |
| Long-Lived Access Token | HA API token (see below) | — |
| Entity Group Name | Prefix for sensor IDs | `proxmox_node` |
| CPU Friendly Name | Display name in HA | `Proxmox CPU Power` |
| Enable GPU? | Only asked if NVIDIA GPU detected | `y` |
| GPU Friendly Name | Display name in HA | `Proxmox GPU Power` |

### Creating a Long-Lived Access Token

1. Open Home Assistant → **Settings** → **People** → your user
2. Scroll to **Long-Lived Access Tokens**
3. Click **Create Token**, give it a name (e.g. `proxmox-power`), and copy the value

## Entities Created in Home Assistant

The setup creates sensor entities with the `power` device class and `W` unit:

- `sensor.<group>_cpu_power` — CPU package power via `turbostat`
- `sensor.<group>_gpu_power` — GPU power via `nvidia-smi` (if enabled)

Both are created as `measurement` state class, making them compatible with HA energy dashboard and long-term statistics.

## Managing the Service

```bash
# Check status
sudo systemctl status proxmox-power

# View live logs
sudo journalctl -u proxmox-power -f

# Stop / start / restart
sudo systemctl stop proxmox-power
sudo systemctl start proxmox-power
sudo systemctl restart proxmox-power

# Disable on boot
sudo systemctl disable proxmox-power
```

## Uninstall

```bash
sudo systemctl stop proxmox-power
sudo systemctl disable proxmox-power
sudo rm /etc/systemd/system/proxmox-power.service
sudo rm /usr/local/bin/proxmox_power_agent.sh
sudo systemctl daemon-reload
```

Then remove the sensor entities from Home Assistant (Settings → Devices & Services → Entities).

## How It Works

```
┌─────────────┐   turbostat / nvidia-smi   ┌──────────────────────┐
│  Proxmox    │ ──────────────────────────► │  Home Assistant      │
│  Host       │   POST /api/states/         │  REST API            │
│  (systemd)  │   every 1 second            │  sensor.*_cpu_power  │
│             │                             │  sensor.*_gpu_power  │
└─────────────┘                             └──────────────────────┘
```

- **CPU**: Uses `turbostat --show PkgWatt` to read the Intel RAPL package power counter.
- **GPU**: Uses `nvidia-smi --query-gpu=power.draw` to read NVIDIA GPU power draw.

## Troubleshooting

**`turbostat` reports no PkgWatt**
Your CPU may not support RAPL. Check with `cat /sys/class/powercap/intel-rapl/intel-rapl:0/name`.

**MSR kernel module fails to load**
Run `sudo modprobe msr` manually. If it fails, your CPU or kernel may not support MSR access.

**Sensor not appearing in Home Assistant**
Verify the token is valid with a manual curl:
```bash
curl -H "Authorization: Bearer YOUR_TOKEN" http://HA_IP:8123/api/
```

## License

MIT
