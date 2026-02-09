#!/bin/bash
set -euo pipefail

# Load environment variables
ENV_FILE=".env"
if [ -f ".env.fabric" ]; then
  ENV_FILE=".env.fabric"
fi

set -a
# Load project defaults first, then overlay with user env file
[ -f "config/.env.defaults" ] && source config/.env.defaults
[ -f "$ENV_FILE" ] && source "$ENV_FILE"
set +a

# Safe defaults for critical env vars (avoid 'unbound variable' with set -u)
CHANNEL_NAME=${CHANNEL_NAME:-mychannel}

# Determine docker compose command and ensure .env is passed for var substitution
if docker compose version > /dev/null 2>&1; then
    DOCKER_COMPOSE=(docker compose --env-file "$ENV_FILE")
elif command -v docker-compose > /dev/null 2>&1; then
    DOCKER_COMPOSE=(docker-compose --env-file "$ENV_FILE")
else
    echo -e "${RED}Neither 'docker compose' nor 'docker-compose' found. Please install Docker Compose.${NC}"
    exit 1
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Helper functions
function printHelp() {
    echo "Usage: "
    echo "  network.sh <mode> [options]"
    echo "    <mode> - one of 'up', 'down', 'restart', 'generate', 'deployCC'"
    echo "      - 'up' - bring up the network"
    echo "      - 'down' - clear the network"
    echo "      - 'restart' - restart the network"
    echo "      - 'generate' - generate crypto material and genesis block"
    echo "      - 'deployCC' - deploy chaincode"
    echo "      - 'createChannel' - create channel"
    echo "      - 'joinChannel' - join peers to channel"
    echo
    echo "  Options:"
    echo "    -ca         - Use Certificate Authorities"
    echo "    -ipfs       - Start IPFS nodes"
    echo "    -explorer   - Start Hyperledger Explorer"
    echo "    -ocr        - Start OCR service"
    echo "    -c <channel name> - Channel name to use (defaults to 'mychannel')"
    echo "    -ccn <name> - Chaincode name"
    echo "    -ccv <version> - Chaincode version"
    echo "    -ccp <path> - Chaincode path"
    echo "    -ccl <language> - Chaincode language (golang, javascript, java, typescript)"
    echo
    echo "  Example:"
    echo "    network.sh up -ca -ipfs -explorer"
    echo "    network.sh deployCC -ccn asset-contract -ccv 1.0 -ccp ./chaincode/asset-contract -ccl golang"
}

function networkUp() {
    echo -e "${GREEN}Starting Fabric network...${NC}"

    if [ "$USE_CA" == "true" ]; then
        echo "Starting Certificate Authorities..."
        "${DOCKER_COMPOSE[@]}" -f docker/docker-compose-ca.yaml up -d
        sleep 5
    fi

    echo "Starting Orderer and Peers..."
    "${DOCKER_COMPOSE[@]}" -f docker/docker-compose-network.yaml up -d

    if [ "$USE_IPFS" == "true" ]; then
        echo "Starting IPFS nodes..."
        "${DOCKER_COMPOSE[@]}" -f docker/docker-compose-ipfs.yaml up -d
    fi

    if [ "$USE_EXPLORER" == "true" ]; then
        echo "Starting Hyperledger Explorer..."
        "${DOCKER_COMPOSE[@]}" -f docker/docker-compose-explorer.yaml up -d
    fi

    if [ "$USE_OCR" == "true" ]; then
        echo "Starting OCR service..."
        "${DOCKER_COMPOSE[@]}" -f docker/docker-compose-ocr.yaml up -d --build
    fi

    echo -e "${GREEN}Network started successfully!${NC}"
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

function networkDown() {
    echo -e "${YELLOW}Stopping Fabric network...${NC}"

    # Do not abort if any of the following commands fail
    set +e

    # Use detected docker compose and pass .env explicitly
    if [ -n "${DOCKER_COMPOSE:-}" ]; then
        "${DOCKER_COMPOSE[@]}" -f docker/docker-compose-explorer.yaml down -v 2>/dev/null || true
        "${DOCKER_COMPOSE[@]}" -f docker/docker-compose-ipfs.yaml down -v 2>/dev/null || true
        "${DOCKER_COMPOSE[@]}" -f docker/docker-compose-network.yaml down -v || true
        "${DOCKER_COMPOSE[@]}" -f docker/docker-compose-ca.yaml down -v 2>/dev/null || true
        "${DOCKER_COMPOSE[@]}" -f docker/docker-compose-ocr.yaml down -v 2>/dev/null || true
    else
        echo -e "${YELLOW}docker compose not available; skipping container cleanup${NC}"
    fi

    # Remove chaincode containers and images
    docker rm -f $(docker ps -aq --filter "name=dev-peer") 2>/dev/null || true
    docker rmi -f $(docker images -q --filter "reference=dev-peer*") 2>/dev/null || true

    # Clean up volumes
    docker volume prune -f 2>/dev/null || true

    # Remove generated artifacts (use Docker to handle root-owned CA files)
    echo "Cleaning up generated artifacts..."
    docker run --rm -v "${PWD}:/work" alpine sh -c \
        "rm -rf /work/organizations/peerOrganizations /work/organizations/ordererOrganizations /work/channel-artifacts/*" 2>/dev/null || true

    echo -e "${GREEN}Network stopped and cleaned up!${NC}"
    # Re-enable 'exit on error' for the rest of the script
    set -e
}

function generateCrypto() {
    echo -e "${GREEN}Generating crypto material...${NC}"

    if [ ! -d "organizations" ]; then
        mkdir -p organizations
    fi

    # Add local bin to PATH
    export PATH=${PWD}/bin:$PATH

    # Generate crypto material using cryptogen
    if [ -f "${PWD}/bin/cryptogen" ] || command -v cryptogen &> /dev/null; then
        cryptogen generate --config=./config/crypto-config.yaml --output="organizations"
        echo -e "${GREEN}Crypto material generated successfully${NC}"
    else
        echo -e "${RED}cryptogen tool not found. Please install Fabric binaries.${NC}"
        exit 1
    fi
}

function generateGenesis() {
    echo -e "${GREEN}Generating genesis block and channel transaction...${NC}"

    if [ ! -d "channel-artifacts" ]; then
        mkdir -p channel-artifacts
    fi

    # Add local bin to PATH
    export PATH=${PWD}/bin:$PATH
    export FABRIC_CFG_PATH=${PWD}/config

    # Generate genesis block for channel
    if [ -f "${PWD}/bin/configtxgen" ] || command -v configtxgen &> /dev/null; then
        configtxgen -profile TwoOrgsApplicationGenesis \
            -outputBlock ./channel-artifacts/${CHANNEL_NAME}.block \
            -channelID ${CHANNEL_NAME}

        echo -e "${GREEN}Genesis block generated successfully${NC}"
    else
        echo -e "${RED}configtxgen tool not found. Please install Fabric binaries.${NC}"
        exit 1
    fi
}

function createChannel() {
    echo -e "${GREEN}Creating channel ${CHANNEL_NAME}...${NC}"

    # Add local bin to PATH
    export PATH=${PWD}/bin:$PATH
    export FABRIC_CFG_PATH=${PWD}/config
    export CORE_PEER_TLS_ENABLED=true
    export CORE_PEER_LOCALMSPID="Org1MSP"
    export CORE_PEER_TLS_ROOTCERT_FILE=${PWD}/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt
    export CORE_PEER_MSPCONFIGPATH=${PWD}/organizations/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp
    export CORE_PEER_ADDRESS=localhost:7051
    export ORDERER_CA=${PWD}/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/msp/tlscacerts/tlsca.example.com-cert.pem

    # Join channel to orderer using osnadmin
    osnadmin channel join --channelID ${CHANNEL_NAME} \
        --config-block ./channel-artifacts/${CHANNEL_NAME}.block \
        -o localhost:7053 \
        --ca-file "$ORDERER_CA" \
        --client-cert ${PWD}/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/tls/server.crt \
        --client-key ${PWD}/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/tls/server.key

    echo -e "${GREEN}Channel ${CHANNEL_NAME} created successfully${NC}"
}

function joinChannel() {
    echo -e "${GREEN}Joining peers to channel ${CHANNEL_NAME}...${NC}"

    # Add local bin to PATH
    export PATH=${PWD}/bin:$PATH
    export FABRIC_CFG_PATH=${PWD}/config

    # Join Org1 Peer0
    export CORE_PEER_TLS_ENABLED=true
    export CORE_PEER_LOCALMSPID="Org1MSP"
    export CORE_PEER_TLS_ROOTCERT_FILE=${PWD}/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt
    export CORE_PEER_MSPCONFIGPATH=${PWD}/organizations/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp
    export CORE_PEER_ADDRESS=localhost:7051

    peer channel join -b ./channel-artifacts/${CHANNEL_NAME}.block
    echo -e "${GREEN}Org1 Peer0 joined channel${NC}"

    # Join Org2 Peer0
    export CORE_PEER_LOCALMSPID="Org2MSP"
    export CORE_PEER_TLS_ROOTCERT_FILE=${PWD}/organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/tls/ca.crt
    export CORE_PEER_MSPCONFIGPATH=${PWD}/organizations/peerOrganizations/org2.example.com/users/Admin@org2.example.com/msp
    export CORE_PEER_ADDRESS=localhost:9051

    peer channel join -b ./channel-artifacts/${CHANNEL_NAME}.block
    echo -e "${GREEN}Org2 Peer0 joined channel${NC}"

    # Join Org3 Peer0 (if exists)
    if [ -d "${PWD}/organizations/peerOrganizations/org3.example.com" ]; then
        export CORE_PEER_LOCALMSPID="Org3MSP"
        export CORE_PEER_TLS_ROOTCERT_FILE=${PWD}/organizations/peerOrganizations/org3.example.com/peers/peer0.org3.example.com/tls/ca.crt
        export CORE_PEER_MSPCONFIGPATH=${PWD}/organizations/peerOrganizations/org3.example.com/users/Admin@org3.example.com/msp
        export CORE_PEER_ADDRESS=localhost:11051

        peer channel join -b ./channel-artifacts/${CHANNEL_NAME}.block
        echo -e "${GREEN}Org3 Peer0 joined channel${NC}"
    else
        echo -e "${YELLOW}Org3 crypto not found; skipping Org3 join${NC}"
    fi

    # Update anchor peers
    updateAnchorPeers
}

function setAnchorPeer() {
    local ORG_MSP=$1
    local ANCHOR_HOST=$2
    local ANCHOR_PORT=$3
    local ORDERER_CA=${PWD}/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/msp/tlscacerts/tlsca.example.com-cert.pem

    echo -e "${YELLOW}Setting anchor peer for ${ORG_MSP}: ${ANCHOR_HOST}:${ANCHOR_PORT}${NC}"

    # Fetch latest config block
    peer channel fetch config channel-artifacts/config_block.pb \
        -o localhost:7050 --ordererTLSHostnameOverride orderer.example.com \
        -c ${CHANNEL_NAME} --tls --cafile "$ORDERER_CA"

    # Decode config block to JSON
    configtxlator proto_decode --input channel-artifacts/config_block.pb \
        --type common.Block --output channel-artifacts/config_block.json

    # Extract config from block
    jq '.data.data[0].payload.data.config' channel-artifacts/config_block.json > channel-artifacts/config.json

    # Create modified config with anchor peer
    jq --arg msp "$ORG_MSP" --arg host "$ANCHOR_HOST" --argjson port "$ANCHOR_PORT" \
        '.channel_group.groups.Application.groups[$msp].values += {"AnchorPeers":{"mod_policy":"Admins","value":{"anchor_peers":[{"host":$host,"port":$port}]},"version":"0"}}' \
        channel-artifacts/config.json > channel-artifacts/modified_config.json

    # Encode original config to protobuf
    configtxlator proto_encode --input channel-artifacts/config.json \
        --type common.Config --output channel-artifacts/original_config.pb

    # Encode modified config to protobuf
    configtxlator proto_encode --input channel-artifacts/modified_config.json \
        --type common.Config --output channel-artifacts/modified_config.pb

    # Compute config update delta
    configtxlator compute_update --channel_id ${CHANNEL_NAME} \
        --original channel-artifacts/original_config.pb \
        --updated channel-artifacts/modified_config.pb \
        --output channel-artifacts/config_update.pb 2>&1 || {
        echo -e "${YELLOW}No anchor peer update needed for ${ORG_MSP} (already set)${NC}"
        return 0
    }

    # Wrap update in envelope
    configtxlator proto_decode --input channel-artifacts/config_update.pb \
        --type common.ConfigUpdate --output channel-artifacts/config_update.json

    echo '{"payload":{"header":{"channel_header":{"channel_id":"'${CHANNEL_NAME}'","type":2}},"data":{"config_update":'$(cat channel-artifacts/config_update.json)'}}}' | \
        jq . > channel-artifacts/config_update_envelope.json

    configtxlator proto_encode --input channel-artifacts/config_update_envelope.json \
        --type common.Envelope --output channel-artifacts/config_update_envelope.pb

    # Submit config update
    peer channel update -f channel-artifacts/config_update_envelope.pb \
        -c ${CHANNEL_NAME} -o localhost:7050 \
        --ordererTLSHostnameOverride orderer.example.com \
        --tls --cafile "$ORDERER_CA"

    echo -e "${GREEN}Anchor peer set for ${ORG_MSP}${NC}"
}

function updateAnchorPeers() {
    echo -e "${GREEN}Updating anchor peers...${NC}"

    # Add local bin to PATH
    export PATH=${PWD}/bin:$PATH
    export FABRIC_CFG_PATH=${PWD}/config

    # Update Org1 anchor peer
    export CORE_PEER_TLS_ENABLED=true
    export CORE_PEER_LOCALMSPID="Org1MSP"
    export CORE_PEER_TLS_ROOTCERT_FILE=${PWD}/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt
    export CORE_PEER_MSPCONFIGPATH=${PWD}/organizations/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp
    export CORE_PEER_ADDRESS=localhost:7051
    setAnchorPeer "Org1MSP" "peer0.org1.example.com" 7051

    # Update Org2 anchor peer
    export CORE_PEER_LOCALMSPID="Org2MSP"
    export CORE_PEER_TLS_ROOTCERT_FILE=${PWD}/organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/tls/ca.crt
    export CORE_PEER_MSPCONFIGPATH=${PWD}/organizations/peerOrganizations/org2.example.com/users/Admin@org2.example.com/msp
    export CORE_PEER_ADDRESS=localhost:9051
    setAnchorPeer "Org2MSP" "peer0.org2.example.com" 9051

    # Update Org3 anchor peer (if exists)
    if [ -d "${PWD}/organizations/peerOrganizations/org3.example.com" ]; then
        export CORE_PEER_LOCALMSPID="Org3MSP"
        export CORE_PEER_TLS_ROOTCERT_FILE=${PWD}/organizations/peerOrganizations/org3.example.com/peers/peer0.org3.example.com/tls/ca.crt
        export CORE_PEER_MSPCONFIGPATH=${PWD}/organizations/peerOrganizations/org3.example.com/users/Admin@org3.example.com/msp
        export CORE_PEER_ADDRESS=localhost:11051
        setAnchorPeer "Org3MSP" "peer0.org3.example.com" 11051
    fi

    echo -e "${GREEN}Anchor peers update completed${NC}"
}

function deployChaincode() {
    echo -e "${GREEN}Deploying chaincode...${NC}"

    # Set defaults if not provided
    CC_NAME=${CC_NAME:-"asset-contract"}
    CC_VERSION=${CC_VERSION:-"1.0"}
    CC_SRC_PATH=${CC_SRC_PATH:-"./chaincode/asset-contract"}
    CC_SEQUENCE=${CC_SEQUENCE:-"1"}
    CC_INIT_FCN=${CC_INIT_FCN:-"NA"}
    CC_END_POLICY=${CC_END_POLICY:-"NA"}
    CC_COLL_CONFIG=${CC_COLL_CONFIG:-"NA"}
    CLI_DELAY=${CLI_DELAY:-"3"}
    MAX_RETRY=${MAX_RETRY:-"5"}
    VERBOSE=${VERBOSE:-"false"}
    CC_SRC_LANGUAGE=${CC_SRC_LANGUAGE:-"golang"}

    ./scripts/deployCC.sh ${CHANNEL_NAME} ${CC_NAME} ${CC_SRC_PATH} ${CC_VERSION} ${CC_SEQUENCE} ${CC_INIT_FCN} ${CC_END_POLICY} ${CC_COLL_CONFIG} ${CLI_DELAY} ${MAX_RETRY} ${VERBOSE} ${CC_SRC_LANGUAGE}
}

# Parse commandline args
MODE=$1
shift

USE_CA="false"
USE_IPFS="false"
USE_EXPLORER="false"
USE_OCR="false"

# Parse flags
while [[ $# -ge 1 ]] ; do
    key="$1"
    case $key in
        -h )
            printHelp
            exit 0
            ;;
        -ca )
            USE_CA="true"
            ;;
        -ipfs )
            USE_IPFS="true"
            ;;
        -explorer )
            USE_EXPLORER="true"
            ;;
        -ocr )
            USE_OCR="true"
            ;;
        -c )
            CHANNEL_NAME="$2"
            shift
            ;;
        -ccn )
            CC_NAME="$2"
            shift
            ;;
        -ccv )
            CC_VERSION="$2"
            shift
            ;;
        -ccp )
            CC_SRC_PATH="$2"
            shift
            ;;
        -ccl )
            CC_SRC_LANGUAGE="$2"
            shift
            ;;
        * )
            echo "Unknown flag: $key"
            printHelp
            exit 1
            ;;
    esac
    shift
done

# Determine mode of operation
if [ "$MODE" == "up" ]; then
    networkUp
elif [ "$MODE" == "down" ]; then
    networkDown
elif [ "$MODE" == "restart" ]; then
    networkDown
    networkUp
elif [ "$MODE" == "generate" ]; then
    generateCrypto
    generateGenesis
elif [ "$MODE" == "createChannel" ]; then
    createChannel
elif [ "$MODE" == "joinChannel" ]; then
    joinChannel
elif [ "$MODE" == "deployCC" ]; then
    deployChaincode
else
    printHelp
    exit 1
fi
