#!/usr/bin/env bash
set -euo pipefail

# Incrementally add Org3 to an existing running network (no full reset)
# - Generates Org3 crypto (cryptogen) if missing
# - Starts peer0.org3 container
# - Updates channel config to include Org3MSP
# - Joins Org3 peer to channel
# - Installs chaincode on Org3 peer (optional approve)
#
# Usage:
#   bash scripts/add_org3.sh [--approve] [--cc-name general] [--cc-version 1.0] [--sequence 1]
#
# Requirements: cryptogen, configtxgen, configtxlator, jq, peer CLI (binaries in ./bin or PATH)

APP_ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
cd "$APP_ROOT"

# Select env file (prefer project-specific .env.fabric if present)
ENV_FILE=".env"
if [ -f ".env.fabric" ]; then
  ENV_FILE=".env.fabric"
fi

# Load defaults then overlay with selected env file
set -a
[ -f "config/.env.defaults" ] && source config/.env.defaults
[ -f "$ENV_FILE" ] && source "$ENV_FILE"
set +a

# Compose wrapper with explicit env-file
if docker compose version > /dev/null 2>&1; then
  DOCKER_COMPOSE=(docker compose --env-file "$ENV_FILE")
elif command -v docker-compose > /dev/null 2>&1; then
  DOCKER_COMPOSE=(docker-compose --env-file "$ENV_FILE")
else
  echo "docker compose not found" >&2; exit 1
fi

APPROVE=false
CC_NAME="${CHAINCODE_NAME:-asset-contract}"
CC_VERSION="${CHAINCODE_VERSION:-1.0}"
CC_SEQUENCE="${CHAINCODE_SEQUENCE:-1}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --approve) APPROVE=true; shift ;;
    --cc-name) CC_NAME="$2"; shift 2 ;;
    --cc-version) CC_VERSION="$2"; shift 2 ;;
    --sequence|--cc-sequence) CC_SEQUENCE="$2"; shift 2 ;;
    -h|--help)
      sed -n '1,60p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# Preflight
export PATH="$APP_ROOT/bin:$PATH"
command -v cryptogen >/dev/null 2>&1 || { echo "cryptogen not found"; exit 1; }
command -v configtxgen >/dev/null 2>&1 || { echo "configtxgen not found"; exit 1; }
command -v configtxlator >/dev/null 2>&1 || { echo "configtxlator not found"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq not found"; exit 1; }
command -v peer >/dev/null 2>&1 || { echo "peer CLI not found"; exit 1; }

CHANNEL_NAME="${CHANNEL_NAME:-mychannel}"
ORDERER_ADDR="localhost:${ORDERER_PORT:-7050}"
ORDERER_CA="$APP_ROOT/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/msp/tlscacerts/tlsca.example.com-cert.pem"

echo "=== Step 1: Ensure Org3 crypto material ==="
if [ ! -d "$APP_ROOT/organizations/peerOrganizations/org3.example.com" ]; then
  cryptogen generate --config=./config/crypto-config-org3.yaml --output=organizations
  echo "Org3 crypto generated"
else
  echo "Org3 crypto already exists, skipping generation"
fi

echo "=== Step 2: Start peer0.org3 ==="
"${DOCKER_COMPOSE[@]}" -f docker/docker-compose-network.yaml up -d peer0.org3.example.com

echo "=== Step 3: Update channel config to include Org3MSP ==="
export FABRIC_CFG_PATH="$APP_ROOT/config"

# Generate Org3 definition JSON
configtxgen -printOrg Org3MSP > org3.json

# Fetch current config block (use Org1 admin identity)
export CORE_PEER_TLS_ENABLED=true
export CORE_PEER_LOCALMSPID="Org1MSP"
export CORE_PEER_TLS_ROOTCERT_FILE=$APP_ROOT/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt
export CORE_PEER_MSPCONFIGPATH=$APP_ROOT/organizations/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp
export CORE_PEER_ADDRESS=localhost:${ORG1_PEER0_PORT:-7051}

peer channel fetch config channel-artifacts/config_block.pb -o "$ORDERER_ADDR" \
  --ordererTLSHostnameOverride orderer.example.com -c "$CHANNEL_NAME" --tls --cafile "$ORDERER_CA"

# Compute update
configtxlator proto_decode --input channel-artifacts/config_block.pb --type common.Block --output config_block.json
jq .data.data[0].payload.data.config config_block.json > config.json
jq -s '.[0] * {channel_group:{groups:{Application:{groups:{Org3MSP:.[1]}}}}}' config.json org3.json > modified_config.json
configtxlator proto_encode --input config.json --type common.Config --output config.pb
configtxlator proto_encode --input modified_config.json --type common.Config --output modified_config.pb
configtxlator compute_update --channel_id "$CHANNEL_NAME" --original config.pb --updated modified_config.pb --output org3_update.pb
configtxlator proto_decode --input org3_update.pb --type common.ConfigUpdate --output org3_update.json
printf '{"payload":{"header":{"channel_header":{"channel_id":"%s","type":2}},"data":{"config_update":' "$CHANNEL_NAME" > prefix.json
echo '}}}' > suffix.json
cat prefix.json org3_update.json suffix.json | jq -s '.[0] + .[1] + .[2]' > org3_update_envelope.json
configtxlator proto_encode --input org3_update_envelope.json --type common.Envelope --output org3_update_envelope.pb

# Sign with Org1
export CORE_PEER_TLS_ENABLED=true
export CORE_PEER_LOCALMSPID="Org1MSP"
export CORE_PEER_TLS_ROOTCERT_FILE=$APP_ROOT/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt
export CORE_PEER_MSPCONFIGPATH=$APP_ROOT/organizations/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp
export CORE_PEER_ADDRESS=localhost:${ORG1_PEER0_PORT:-7051}
peer channel signconfigtx -f org3_update_envelope.pb

# Sign with Org2
export CORE_PEER_LOCALMSPID="Org2MSP"
export CORE_PEER_TLS_ROOTCERT_FILE=$APP_ROOT/organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/tls/ca.crt
export CORE_PEER_MSPCONFIGPATH=$APP_ROOT/organizations/peerOrganizations/org2.example.com/users/Admin@org2.example.com/msp
export CORE_PEER_ADDRESS=localhost:${ORG2_PEER0_PORT:-9051}
peer channel signconfigtx -f org3_update_envelope.pb

# Submit update (as Org1)
export CORE_PEER_LOCALMSPID="Org1MSP"
export CORE_PEER_TLS_ROOTCERT_FILE=$APP_ROOT/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt
export CORE_PEER_MSPCONFIGPATH=$APP_ROOT/organizations/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp
export CORE_PEER_ADDRESS=localhost:${ORG1_PEER0_PORT:-7051}
peer channel update -f org3_update_envelope.pb -c "$CHANNEL_NAME" -o "$ORDERER_ADDR" \
  --ordererTLSHostnameOverride orderer.example.com --tls --cafile "$ORDERER_CA"

echo "=== Step 4: Join Org3 peer to channel ==="
export CORE_PEER_LOCALMSPID="Org3MSP"
export CORE_PEER_TLS_ROOTCERT_FILE=$APP_ROOT/organizations/peerOrganizations/org3.example.com/peers/peer0.org3.example.com/tls/ca.crt
export CORE_PEER_MSPCONFIGPATH=$APP_ROOT/organizations/peerOrganizations/org3.example.com/users/Admin@org3.example.com/msp
export CORE_PEER_ADDRESS=localhost:${ORG3_PEER0_PORT:-11051}

peer channel join -b ./channel-artifacts/${CHANNEL_NAME}.block
peer channel getinfo -c "$CHANNEL_NAME"

echo "=== Step 5: Install chaincode on Org3 peer ==="
if [ -f "${CC_NAME}.tar.gz" ]; then
  echo "Using existing package ${CC_NAME}.tar.gz"
else
  echo "WARN: ${CC_NAME}.tar.gz not found in repo root; install step may fail."
fi

peer lifecycle chaincode install ${CC_NAME}.tar.gz || true

if $APPROVE; then
  echo "Approving chaincode for Org3 (sequence ${CC_SEQUENCE})..."
  peer lifecycle chaincode queryinstalled >& log.txt || true
  PACKAGE_ID=$(sed -n "/${CC_NAME}_${CC_VERSION}/{s/^Package ID: //; s/, Label:.*$//; p;}" log.txt || true)
  if [ -n "${PACKAGE_ID:-}" ]; then
    peer lifecycle chaincode approveformyorg \
      -o "$ORDERER_ADDR" \
      --ordererTLSHostnameOverride orderer.example.com \
      --tls --cafile "$ORDERER_CA" \
      --channelID "$CHANNEL_NAME" \
      --name "$CC_NAME" \
      --version "$CC_VERSION" \
      --package-id "$PACKAGE_ID" \
      --sequence "$CC_SEQUENCE" || true
  else
    echo "WARN: PACKAGE_ID not found in log.txt; skip approve"
  fi
fi

echo "=== Org3 added incrementally without reset ==="
