# Proxmox Power Monitor Agent for Home Assistant

One-shot setup scripts that deploy a systemd service on your Proxmox host to push real-time CPU (and optional NVIDIA GPU) power draw to [Home Assistant](https://www.home-assistant.io/).

Two methods are available:

| | REST API | MQTT (recommended) |
|---|---|---|
| Script | `setup_power_agent.sh` | `setup_power_agent_mqtt.sh` |
| HA integration | Built-in REST API | MQTT discovery |
| Unique ID | No — entities can't be renamed from UI | Yes — fully manageable from UI |
| Survives HA restart | No | Yes |
| Extra dependency | None | MQTT broker |
| HA token required | Yes | No |

## Requirements

- **Proxmox VE host** (Debian-based, using `apt` as the package manager — run as root or with sudo)
- **Intel CPU** with RAPL support (required by `turbostat` for `PkgWatt` readings)
- **NVIDIA GPU** (optional — auto-detected if `nvidia-smi` is present)
- **MQTT broker** (only for MQTT method — e.g. Mosquitto add-on in HA)

## Quick Start

```bash
git clone https://github.com/HRNPH/homeassistant-software-based-power-monitor-agent.git
cd homeassistant-software-based-power-monitor-agent

# Pick one:
sudo bash setup_power_agent_mqtt.sh   # MQTT (recommended)
sudo bash setup_power_agent.sh        # REST API

cd .. && rm -rf homeassistant-software-based-power-monitor-agent
```

Both scripts are interactive and will guide you through configuration.

---

## MQTT Method (`setup_power_agent_mqtt.sh`)

### What it needs

- An MQTT broker accessible from the Proxmox host (e.g. the Mosquitto add-on in HA)
- HA must have the **MQTT** integration configured (Settings → Devices & Services → Add Integration → MQTT)

### Setup prompts

| Prompt | Description | Default |
|--------|-------------|---------|
| MQTT Broker IP/Host | Address of your MQTT broker | — |
| MQTT Broker Port | Port number | `1883` |
| MQTT Username | Broker username (leave blank if none) | — |
| MQTT Password | Broker password | — |
| Proxmox Node ID | Prefix for entity IDs | `proxmox_node` |
| CPU Friendly Name | Display name in HA | `Proxmox CPU Power` |
| Enable GPU? | Only asked if NVIDIA GPU detected | `y` |
| GPU Friendly Name | Display name in HA | `Proxmox GPU Power` |

### How it works

```
┌─────────────┐                        ┌─────────────┐   discovery   ┌──────────────────┐
│  Proxmox    │  mosquitto_pub         │  MQTT       │ ───────────── │  Home Assistant  │
│  Host       │ ─────────────────────► │  Broker     │               │  auto-creates    │
│  (systemd)  │  every 1 second        │             │  state        │  entities with   │
│             │                        │             │ ◄───────────── │  unique_id       │
└─────────────┘                        └─────────────┘               └──────────────────┘
```

1. Publishes a retained MQTT discovery message — HA auto-creates entities with `unique_id`
2. Publishes power readings to state topics every second
3. Entities are fully manageable from the HA UI and survive restarts

### Uninstall

```bash
# Stop and remove service
sudo systemctl stop proxmox-power-mqtt
sudo systemctl disable proxmox-power-mqtt
sudo rm /etc/systemd/system/proxmox-power-mqtt.service
sudo rm /usr/local/bin/proxmox_power_agent_mqtt.sh
sudo systemctl daemon-reload

# Remove discovery configs so HA deletes the entities
mosquitto_pub -h BROKER_IP -u USER -P PASS -t "homeassistant/sensor/NODE_ID/cpu_power/config" -r -n
mosquitto_pub -h BROKER_IP -u USER -P PASS -t "homeassistant/sensor/NODE_ID/gpu_power/config" -r -n
rm -rf ~/homeassistant-software-based-power-monitor-agent
```

---

## REST API Method (`setup_power_agent.sh`)

### Setup prompts

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

### How it works

```
┌─────────────┐   POST /api/states/   ┌──────────────────┐
│  Proxmox    │ ────────────────────► │  Home Assistant  │
│  Host       │   every 1 second      │  REST API        │
│  (systemd)  │                       └──────────────────┘
└─────────────┘
```

Pushes readings to the HA REST API. Entities lack a `unique_id` so they **cannot be renamed or deleted from the HA UI** and **do not survive HA restarts**. Use the MQTT method if these limitations are a problem.

### Uninstall

```bash
sudo systemctl stop proxmox-power
sudo systemctl disable proxmox-power
sudo rm /etc/systemd/system/proxmox-power.service
sudo rm /usr/local/bin/proxmox_power_agent.sh
sudo systemctl daemon-reload
rm -rf ~/homeassistant-software-based-power-monitor-agent
```

Then delete the sensor entities from HA via the REST API:
```bash
curl -X DELETE -H "Authorization: Bearer YOUR_TOKEN" http://HA_IP:8123/api/states/sensor.NODE_cpu_power
```

---

## Managing the Service

```bash
# MQTT method
sudo systemctl status proxmox-power-mqtt
sudo journalctl -u proxmox-power-mqtt -f

# REST API method
sudo systemctl status proxmox-power
sudo journalctl -u proxmox-power -f
```

Both services auto-start on boot and restart on failure.

## Troubleshooting

**`turbostat` reports no PkgWatt**
Your CPU may not support RAPL. Check with `cat /sys/class/powercap/intel-rapl/intel-rapl:0/name`.

**MSR kernel module fails to load**
Run `sudo modprobe msr` manually. If it fails, your CPU or kernel may not support MSR access.

**MQTT broker connection fails**
Verify the broker is running and credentials are correct: `mosquitto_sub -h BROKER_IP -u USER -P PASS -t "test" -V mqttv311`

**REST API entities missing after HA restart**
This is expected — the REST API method doesn't persist entities. Re-run the setup script or switch to the MQTT method.

## License

MIT
