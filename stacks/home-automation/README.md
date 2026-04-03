# 🏠 Home Automation Stack

> Home Assistant + Node-RED + Zigbee2MQTT + Mosquitto — the complete open-source home automation foundation for ~$130 USDT.

## Stack Components

| Service | Image | Port | Purpose |
|---------|-------|------|---------|
| **Home Assistant** | `homeassistant/home-assistant:latest` | 8123 | Core home automation platform |
| **Node-RED** | `nodered/node-red:latest` | 1880 | Visual flow-based automation |
| **Zigbee2MQTT** | `koenkk/zigbee2mqtt:latest` | 8080 | Zigbee bridge (MQTT ↔ Zigbee) |
| **Mosquitto** | `eclipse-mosquitto:latest` | 1883 | MQTT broker |

## Hardware Requirements (~ $130 USDT)

| Item | Est. Cost | Notes |
|------|-----------|-------|
| Raspberry Pi 4 (4GB) | ~$55 | Or any x86_64 SBC/nas |
| 32GB SD Card | ~$8 | Class A2 recommended |
| **Zigbee USB Stick** (SONOFF Zigbee 3.0 Dongle Plus recommended) | ~$20 | CC2652 chip, +$5 for case |
| Smart home devices (Zigbee) | ~$47 | Bulbs, sensors, switches |
| **Total** | **~$130** | |

> Recommended Zigbee stick: [SONOFF Zigbee 3.0 USB Dongle Plus](https://itead.cc/product/sonoff-zigbee-3-0-usb-dongle-plus/) (~$20) — flash with Z-Stack firmware for best compatibility.

## Quick Start

### 1. Prerequisites

```bash
# Install Docker & Docker Compose
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
newgrp docker

# Verify Docker
docker --version
docker compose version
```

### 2. Clone & Configure

```bash
git clone https://github.com/illbnm/homelab-stack.git
cd homelab-stack/stacks/home-automation

# Copy environment template
cp .env.example .env
# Edit .env — set DOMAIN, TZ, MQTT credentials, ZIGBEE_DEVICE
nano .env
```

### 3. Configure Zigbee Stick

Find your USB Zigbee stick device path:

```bash
# List USB devices
ls -la /dev/serial/by-id/
# Or
dmesg | grep tty

# Common paths: /dev/ttyACM0, /dev/ttyUSB0, /dev/ttyACM1
```

Update `ZIGBEE_DEVICE` in `.env` to match (e.g., `/dev/ttyACM0`).

### 4. Generate MQTT Password

```bash
# Start mosquitto first to generate the password file
docker compose up -d mosquitto
docker exec mosquitto sh -c "echo 'mosquitto:$(mosquitto_passwd -c /mosquitto/config/passwords.txt mosquitto)' > /tmp/gen.sh" 2>/dev/null || true

# Generate password hash manually (install mosquitto_passwd if needed)
# mosquitto_passwd -c passwords.txt mosquitto
# Then enter your password when prompted

# Or use this one-liner to generate a bcrypt hash
docker run --rm -it eclipse-mosquitto:latest \
  sh -c "echo 'mosquitto:$(mosquitto_passwd -nr -b /dev/stdin mosquitto changeme_1234)'" > passwords.txt
```

> **Security note:** Change default MQTT credentials before exposing to the internet.

### 5. Deploy

```bash
docker compose up -d
```

Check service health:

```bash
docker compose ps
docker compose logs -f [service-name]
```

### 6. Access Services

| Service | URL | First-run |
|---------|-----|-----------|
| Home Assistant | http://your-host:8123 | onboarding wizard |
| Node-RED | http://your-host:1880 | drag & drop flows |
| Zigbee2MQTT | http://your-host:8080 | permit join to add devices |

## Network Configuration

All services use `network_mode: host` for best compatibility with multicast/broadcast (Zigbee discovery, mDNS, etc.).

```
┌─────────────────────────────────────────────────────────┐
│                     Your Network                         │
│                                                          │
│  Home Assistant  :8123  ←─────────────────────────────  │
│  Node-RED        :1880  ←──────┐                         │
│  Zigbee2MQTT     :8080  ←──────┼──► /dev/ttyACM0 (Zigbee│
│  Mosquitto       :1883  ←──────┘    USB Stick)         │
│                                                          │
│  Zigbee Devices  ◄──────── MQTT ───────── Zigbee2MQTT  │
└─────────────────────────────────────────────────────────┘
```

## Adding Zigbee Devices

1. Open Zigbee2MQTT UI → **Permit Join** (top right)
2. Power on your Zigbee device in pairing mode
3. Device appears — rename it in `zigbee2mqtt-data/configuration.yaml`
4. Restart Zigbee2MQTT

## Data Persistence

| Volume | Path | Contents |
|--------|------|----------|
| `ha-config` | `/config` | Home Assistant config, automations, integrations |
| `node-red-data` | `/data` | Flows, credentials, settings |
| `zigbee2mqtt-data` | `/app/data` | `configuration.yaml`, device DB (`Coordinator.json`) |
| `mosquitto-data` | `/mosquitto/data` | MQTT persistence (retains messages) |
| `mosquitto-logs` | `/mosquitto/log` | Broker logs |

**Back up these volumes regularly!**

## Mosquitto MQTT Credentials

After generating passwords with `mosquitto_passwd`, configure Home Assistant:

1. Home Assistant → **Settings** → **Devices & Services** → **MQTT** → **Configure**
2. Enter broker IP, port `1883`, username `mosquitto`, your password

Node-RED MQTT nodes: use `mqtt://host:1883` with same credentials.

## Recommended Upgrades

- **SSD boot** for Raspberry Pi (faster, more reliable than SD)
- **UPS** for power protection
- **Let's Encrypt** wildcard cert + Traefik for HTTPS (see `base/` stack)
- **Zigbee signal** — add a Zigbee mesh router device (smart plug) for larger homes

## Cost Breakdown

```
Raspberry Pi 4B 4GB          $55
32GB SD Card (A2)             $8
Zigbee 3.0 USB Dongle Plus   $20
Zigbee smart bulbs (3x)      $20
Zigbee temp/humidity sensor  $10
Zigbee smart switch          $17
────────────────────────────────
Total                         $130
```

## References

- [Home Assistant Docs](https://www.home-assistant.io/docs/)
- [Node-RED Docs](https://nodered.org/docs/)
- [Zigbee2MQTT Docs](https://www.zigbee2mqtt.io/)
- [Mosquitto Docs](https://mosquitto.org/documentation/)
- [SONOFF Zigbee 3.0 Dongle Flashing](https://sonoff.tech/blog/news/sonoff-zigbee-3-0-usb-dongle-plus-firmware-flashing/)
