#!/bin/bash
clear
echo "=========================================================="
echo "   PROXMOX TO HOME ASSISTANT POWER AGENT (MQTT) SETUP    "
echo "=========================================================="
echo ""

# ---------------------------------------------------------
# PRE-REQUISITE CHECKUP
# ---------------------------------------------------------
echo "[*] Running system pre-requisite checkup..."
MISSING_DEPS=()

# Check system core bins
for cmd in sed stdbuf xargs; do
    if ! command -v $cmd &> /dev/null; then
        MISSING_DEPS+=("$cmd")
    fi
done

# Check for mosquitto-clients (provides mosquitto_pub)
if ! command -v mosquitto_pub &> /dev/null; then
    MISSING_DEPS+=("mosquitto-clients")
fi

# Check for jq (needed for MQTT discovery JSON)
if ! command -v jq &> /dev/null; then
    MISSING_DEPS+=("jq")
fi

# Check for turbostat (provided by linux-cpupower package on Debian/Proxmox)
if ! command -v turbostat &> /dev/null; then
    echo "[-] WARNING: 'turbostat' CLI is missing."
    MISSING_DEPS+=("linux-cpupower")
fi

# Check for MSR kernel module capability (Required by turbostat)
if ! lsmod | grep -q "^msr" && [ ! -c /dev/cpu/0/msr ]; then
    echo "[-] WARNING: MSR kernel module is not loaded."
    modprobe msr && echo "msr" >> /etc/modules 2>/dev/null
    if [ $? -ne 0 ]; then
        echo "[!] CRITICAL: Failed to load MSR kernel module. Run as root or verify CPU support."
        exit 1
    fi
    echo "[+] Successfully loaded MSR kernel driver."
fi

# Handle missing packages automatically
if [ ${#MISSING_DEPS[@]} -ne 0 ]; then
    echo -e "\n[!] Found missing dependencies: ${MISSING_DEPS[*]}"
    read -p "Would you like to install them via apt right now? (y/n) [y]: " INSTALL_CONF
    INSTALL_CONF=${INSTALL_CONF:-y}
    if [[ "$INSTALL_CONF" =~ ^[Yy]$ ]]; then
        echo "[*] Updating package index and installing dependencies..."
        apt-get update -y && apt-get install -y "${MISSING_DEPS[@]}"

        if ! command -v turbostat &> /dev/null; then
            echo "[!] Error: Installation completed but 'turbostat' is still missing. Aborting."
            exit 1
        fi
    else
        echo "[!] Aborting setup due to missing dependencies."
        exit 1
    fi
fi

echo "[+] Dependency checks passed cleanly. Proceeding to configuration."
echo "=========================================================="
echo ""

# ---------------------------------------------------------
# RE-INSTALL DETECTION
# ---------------------------------------------------------
AGENT_PATH="/usr/local/bin/proxmox_power_agent_mqtt.sh"
OLD_MQTT_HOST="" OLD_MQTT_PORT="" OLD_MQTT_USER="" OLD_MQTT_PASS=""
OLD_ENTITY_GROUP="" OLD_HAS_NVIDIA="false"

if [ -f "$AGENT_PATH" ]; then
    echo "[*] Existing installation detected at ${AGENT_PATH}"
    OLD_MQTT_HOST=$(grep -oP '^MQTT_HOST="\K[^"]+' "$AGENT_PATH")
    OLD_MQTT_PORT=$(grep -oP '^MQTT_PORT="\K[^"]+' "$AGENT_PATH")
    OLD_MQTT_USER=$(grep -oP '^MQTT_USER="\K[^"]+' "$AGENT_PATH")
    OLD_MQTT_PASS=$(grep -oP '^MQTT_PASS="\K[^"]+' "$AGENT_PATH")
    OLD_ENTITY_GROUP=$(grep -oP '^NODE_ID="\K[^"]+' "$AGENT_PATH")
    OLD_HAS_NVIDIA=$(grep -oP 'if \[ "\K[^"]+' "$AGENT_PATH" | head -1)

    echo "[*] Stopping existing service for update..."
    systemctl stop proxmox-power-mqtt.service 2>/dev/null
    echo ""
fi

# ---------------------------------------------------------
# INTERACTIVE CONFIGURATION TUI
# ---------------------------------------------------------
# 1. MQTT Broker Configuration
read -p "Enter MQTT Broker IP/Host (e.g., 192.168.1.50) [${OLD_MQTT_HOST}]: " MQTT_HOST
MQTT_HOST=${MQTT_HOST:-$OLD_MQTT_HOST}
read -p "Enter MQTT Broker Port [${OLD_MQTT_PORT:-1883}]: " MQTT_PORT
MQTT_PORT=${MQTT_PORT:-${OLD_MQTT_PORT:-1883}}
read -p "Enter MQTT Username (leave blank if none) [${OLD_MQTT_USER}]: " MQTT_USER
MQTT_USER=${MQTT_USER:-$OLD_MQTT_USER}
read -p "Enter MQTT Password [${OLD_MQTT_PASS}]: " MQTT_PASS
MQTT_PASS=${MQTT_PASS:-$OLD_MQTT_PASS}

# 2. Entity Configuration
read -p "Enter Proxmox Node ID [${OLD_ENTITY_GROUP:-proxmox_node}]: " NODE_ID
NODE_ID=${NODE_ID:-${OLD_ENTITY_GROUP:-proxmox_node}}

read -p "Enter CPU Entity Friendly Name [Proxmox CPU Power]: " CPU_NAME
CPU_NAME=${CPU_NAME:-Proxmox CPU Power}
CPU_OBJ_ID=$(echo "${NODE_ID}_cpu_power" | tr '[:upper:]' '[:lower:]' | tr ' ' '_')

# 3. GPU Telemetry Auto-Detection
HAS_NVIDIA=false
if command -v nvidia-smi &> /dev/null; then
    echo -e "\n[+] NVIDIA GPU Detected!"
    read -p "Do you want to export GPU power data too? (y/n) [y]: " WANT_GPU
    WANT_GPU=${WANT_GPU:-y}
    if [[ "$WANT_GPU" =~ ^[Yy]$ ]]; then
        HAS_NVIDIA=true
        read -p "Enter GPU Entity Friendly Name [Proxmox GPU Power]: " GPU_NAME
        GPU_NAME=${GPU_NAME:-Proxmox GPU Power}
        GPU_OBJ_ID=$(echo "${NODE_ID}_gpu_power" | tr '[:upper:]' '[:lower:]' | tr ' ' '_')
    fi
fi

# ---------------------------------------------------------
# MQTT CONNECTIVITY TEST
# ---------------------------------------------------------
MQTT_PUB_ARGS="-h $MQTT_HOST -p $MQTT_PORT"
if [ -n "$MQTT_USER" ]; then
    MQTT_PUB_ARGS="$MQTT_PUB_ARGS -u $MQTT_USER -P $MQTT_PASS"
fi

echo -e "\n[*] Testing MQTT broker connection..."
mosquitto_pub $MQTT_PUB_ARGS -t "proxmox/test" -m "ping" 2>/dev/null
if [ $? -ne 0 ]; then
    echo "[!] CRITICAL: Cannot connect to MQTT broker at ${MQTT_HOST}:${MQTT_PORT}. Aborting."
    exit 1
fi
echo "[+] MQTT broker connection successful."

# ---------------------------------------------------------
# 4. PUBLISH MQTT DISCOVERY CONFIGS
# ---------------------------------------------------------
echo "[*] Publishing MQTT auto-discovery configs..."

# Build mosquitto_pub base command for reuse
MPUB="mosquitto_pub $MQTT_PUB_ARGS"

# CPU discovery
CPU_DISCOVERY=$(jq -n \
    --arg name "$CPU_NAME" \
    --arg uid "${NODE_ID}_${CPU_OBJ_ID}" \
    --arg state_topic "proxmox/${NODE_ID}/cpu_power" \
    '{name: $name, unique_id: $uid, state_topic: $state_topic, unit_of_measurement: "W", device_class: "power", state_class: "measurement"}')

$MPUB -t "homeassistant/sensor/${NODE_ID}/${CPU_OBJ_ID}/config" -r -m "$CPU_DISCOVERY"

# GPU discovery
if [ "$HAS_NVIDIA" = true ]; then
    GPU_DISCOVERY=$(jq -n \
        --arg name "$GPU_NAME" \
        --arg uid "${NODE_ID}_${GPU_OBJ_ID}" \
        --arg state_topic "proxmox/${NODE_ID}/gpu_power" \
        '{name: $name, unique_id: $uid, state_topic: $state_topic, unit_of_measurement: "W", device_class: "power", state_class: "measurement"}')

    $MPUB -t "homeassistant/sensor/${NODE_ID}/${GPU_OBJ_ID}/config" -r -m "$GPU_DISCOVERY"
fi

echo "[+] Discovery configs published. HA will auto-create the entities."

# ---------------------------------------------------------
# 5. GENERATE RUNTIME AGENT SCRIPT
# ---------------------------------------------------------
echo "[+] Generating runtime script at ${AGENT_PATH}..."

cat << 'EOF' > $AGENT_PATH
#!/bin/bash
MQTT_HOST="MQTT_PLACEHOLDER_HOST"
MQTT_PORT="MQTT_PLACEHOLDER_PORT"
MQTT_USER="MQTT_PLACEHOLDER_USER"
MQTT_PASS="MQTT_PLACEHOLDER_PASS"
NODE_ID="NODE_PLACEHOLDER_ID"
CPU_STATE_TOPIC="proxmox/${NODE_ID}/cpu_power"
GPU_STATE_TOPIC="proxmox/${NODE_ID}/gpu_power"

MPUB="mosquitto_pub -h $MQTT_HOST -p $MQTT_PORT"
if [ -n "$MQTT_USER" ]; then
    MPUB="$MPUB -u $MQTT_USER -P $MQTT_PASS"
fi

while true; do
    # Extract CPU Power
    cpu_watt=$(stdbuf -oL turbostat --Summary --quiet --show PkgWatt --interval 1 --num_iterations 1 | tail -n 1 | xargs)
    if [[ ! -z "$cpu_watt" && "$cpu_watt" != "PkgWatt" ]]; then
        $MPUB -t "$CPU_STATE_TOPIC" -m "$cpu_watt"
    fi

    # Extract GPU Power if enabled
    if [ "HAS_GPU_PLACEHOLDER" = true ]; then
        gpu_watt=$(nvidia-smi --query-gpu=power.draw --format=csv,noheader,nounits | xargs)
        if [[ ! -z "$gpu_watt" ]]; then
            $MPUB -t "$GPU_STATE_TOPIC" -m "$gpu_watt"
        fi
    fi
    sleep 1
done
EOF

# Inject variables
sed -i "s|MQTT_PLACEHOLDER_HOST|$MQTT_HOST|g" $AGENT_PATH
sed -i "s|MQTT_PLACEHOLDER_PORT|$MQTT_PORT|g" $AGENT_PATH
sed -i "s|MQTT_PLACEHOLDER_USER|$MQTT_USER|g" $AGENT_PATH
sed -i "s|MQTT_PLACEHOLDER_PASS|$MQTT_PASS|g" $AGENT_PATH
sed -i "s|NODE_PLACEHOLDER_ID|$NODE_ID|g" $AGENT_PATH
sed -i "s|HAS_GPU_PLACEHOLDER|$HAS_NVIDIA|g" $AGENT_PATH

chmod +x $AGENT_PATH

# ---------------------------------------------------------
# 6. CREATE SYSTEMD SERVICE
# ---------------------------------------------------------
SERVICE_FILE="/etc/systemd/system/proxmox-power-mqtt.service"
echo "[+] Creating background service at ${SERVICE_FILE}..."

cat << EOF > $SERVICE_FILE
[Unit]
Description=Proxmox Power Agent to Home Assistant (MQTT)
After=network.target

[Service]
ExecStart=$AGENT_PATH
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# ---------------------------------------------------------
# 7. START SERVICE
# ---------------------------------------------------------
echo "[+] Starting background service..."
systemctl daemon-reload
systemctl enable --now proxmox-power-mqtt.service

echo -e "\n=========================================================="
echo " Setup Finished Successfully!"
echo " CPU Entity in HA: sensor.${CPU_OBJ_ID}"
if [ "$HAS_NVIDIA" = true ]; then
    echo " GPU Entity in HA: sensor.${GPU_OBJ_ID}"
fi
echo ""
echo " Entities are fully manageable from the HA UI."
echo "=========================================================="
