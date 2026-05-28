#!/bin/bash
clear
echo "=========================================================="
echo "      TURBOSTAT TO HOME ASSISTANT POWER AGENT SETUP         "
echo "=========================================================="
echo ""

# ---------------------------------------------------------
# PRE-REQUISITE CHECKUP
# ---------------------------------------------------------
echo "[*] Running system pre-requisite checkup..."
MISSING_DEPS=()

# Check system core bins
for cmd in curl sed stdbuf xargs; do
    if ! command -v $cmd &> /dev/null; then
        MISSING_DEPS+=("$cmd")
    fi
done

# Check for turbostat (provided by linux-cpupower package on Debian/Proxmox)
if ! command -v turbostat &> /dev/null; then
    echo "[-] WARNING: 'turbostat' CLI is missing."
    MISSING_DEPS+=("linux-cpupower")
fi

# Check for MSR kernel module capability (Required by turbostat)
if ! lsmod | grep -q "^msr" && [ ! -c /dev/cpu/0/msr ]; then
    echo "[-] WARNING: MSR kernel module is not loaded."
    # Attempt to instantly enable it
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

        # Verify if setup now passes
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
# INTERACTIVE CONFIGURATION TUI
# ---------------------------------------------------------
# 1. Gather API Configuration
read -p "Enter Home Assistant IP/Host (e.g., 192.168.1.50): " HA_IP
read -p "Enter Home Assistant Port [8123]: " HA_PORT
HA_PORT=${HA_PORT:-8123}
read -p "Enter Home Assistant Long-Lived Access Token: " HA_TOKEN

# 2. Entity Configuration
read -p "Enter Proxmox Node ID/Group name [proxmox_node]: " ENTITY_GROUP
ENTITY_GROUP=${ENTITY_GROUP:-proxmox_node}

read -p "Enter CPU Entity Friendly Name [Proxmox CPU Power]: " CPU_NAME
CPU_NAME=${CPU_NAME:-Proxmox CPU Power}
CPU_ID=$(echo "${ENTITY_GROUP}_cpu_power" | tr '[:upper:]' '[:lower:]' | tr ' ' '_')

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
        GPU_ID=$(echo "${ENTITY_GROUP}_gpu_power" | tr '[:upper:]' '[:lower:]' | tr ' ' '_')
    fi
fi

# 4. Generate the Active Exporter Agent Script
AGENT_PATH="/usr/local/bin/proxmox_power_agent.sh"
echo -e "\n[+] Generating runtime script at ${AGENT_PATH}..."

cat << 'EOF' > $AGENT_PATH
#!/bin/bash
HA_BASE_URL="http://HA_PLACEHOLDER_IP:HA_PLACEHOLDER_PORT/api/states"
TOKEN="HA_PLACEHOLDER_TOKEN"
CPU_URL="${HA_BASE_URL}/sensor.CPU_PLACEHOLDER_ID"
GPU_URL="${HA_BASE_URL}/sensor.GPU_PLACEHOLDER_ID"

send_to_ha() {
    local url=$1 val=$2 name=$3 unique_id=$4
    curl -s -X POST -H "Authorization: Bearer $TOKEN" \
         -H "Content-Type: application/json" \
         -d "{\"state\": \"$val\", \"unique_id\": \"$unique_id\", \"attributes\": {\"unit_of_measurement\": \"W\", \"device_class\": \"power\", \"state_class\": \"measurement\", \"friendly_name\": \"$name\"}}" \
         "$url" > /dev/null
}

while true; do
    # Extract CPU Power
    cpu_watt=$(stdbuf -oL turbostat --Summary --quiet --show PkgWatt --interval 1 --num_iterations 1 | tail -n 1 | xargs)
    if [[ ! -z "$cpu_watt" && "$cpu_watt" != "PkgWatt" ]]; then
        send_to_ha "$CPU_URL" "$cpu_watt" "CPU_PLACEHOLDER_NAME" "CPU_PLACEHOLDER_ID_uid"
    fi

    # Extract GPU Power if enabled
    if [ "HAS_GPU_PLACEHOLDER" = true ]; then
        gpu_watt=$(nvidia-smi --query-gpu=power.draw --format=csv,noheader,nounits | xargs)
        if [[ ! -z "$gpu_watt" ]]; then
            send_to_ha "$GPU_URL" "$gpu_watt" "GPU_PLACEHOLDER_NAME" "GPU_PLACEHOLDER_ID_uid"
        fi
    fi
    sleep 1
done
EOF

# Inject variables safely into the template script
sed -i "s|HA_PLACEHOLDER_IP|$HA_IP|g" $AGENT_PATH
sed -i "s|HA_PLACEHOLDER_PORT|$HA_PORT|g" $AGENT_PATH
sed -i "s|HA_PLACEHOLDER_TOKEN|$HA_TOKEN|g" $AGENT_PATH
sed -i "s|CPU_PLACEHOLDER_ID|$CPU_ID|g" $AGENT_PATH
sed -i "s|CPU_PLACEHOLDER_NAME|$CPU_NAME|g" $AGENT_PATH
sed -i "s|HAS_GPU_PLACEHOLDER|$HAS_NVIDIA|g" $AGENT_PATH

if [ "$HAS_NVIDIA" = true ]; then
    sed -i "s|GPU_PLACEHOLDER_ID|$GPU_ID|g" $AGENT_PATH
    sed -i "s|GPU_PLACEHOLDER_NAME|$GPU_NAME|g" $AGENT_PATH
fi

chmod +x $AGENT_PATH

# 5. Create Systemd Daemon Service
SERVICE_FILE="/etc/systemd/system/proxmox-power.service"
echo "[+] Creating background service at ${SERVICE_FILE}..."

cat << EOF > $SERVICE_FILE
[Unit]
Description=Proxmox Smart Power Agent to Home Assistant
After=network.target

[Service]
ExecStart=$AGENT_PATH
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# 6. Initialize Service
echo "[+] Starting background services..."
systemctl daemon-reload
systemctl enable --now proxmox-power.service

echo -e "\n=========================================================="
echo " Setup Finished Successfully!"
echo " CPU Entity in HA: sensor.${CPU_ID}"
if [ "$HAS_NVIDIA" = true ]; then
    echo " GPU Entity in HA: sensor.${GPU_ID}"
fi
echo "=========================================================="
