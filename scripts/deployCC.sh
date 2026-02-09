#!/bin/bash
set -euo pipefail

# Chaincode deployment script
CHANNEL_NAME=${1:-"mychannel"}
CC_NAME=${2:-"asset-contract"}
CC_SRC_PATH=${3:-"../chaincode/asset-contract"}
CC_VERSION=${4:-"1.0"}
CC_SEQUENCE=${5:-"1"}
CC_INIT_FCN=${6:-"NA"}
CC_END_POLICY=${7:-"NA"}
CC_COLL_CONFIG=${8:-"NA"}
DELAY=${9:-"3"}
MAX_RETRY=${10:-"5"}
VERBOSE=${11:-"false"}
CC_SRC_LANGUAGE=${12:-"golang"}

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Set environment for Org1
setGlobalsForOrg1() {
    export CORE_PEER_LOCALMSPID="Org1MSP"
    export CORE_PEER_TLS_ROOTCERT_FILE=$PWD/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt
    export CORE_PEER_MSPCONFIGPATH=$PWD/organizations/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp
    export CORE_PEER_ADDRESS=localhost:7051
}

# Set environment for Org2
setGlobalsForOrg2() {
    export CORE_PEER_LOCALMSPID="Org2MSP"
    export CORE_PEER_TLS_ROOTCERT_FILE=$PWD/organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/tls/ca.crt
    export CORE_PEER_MSPCONFIGPATH=$PWD/organizations/peerOrganizations/org2.example.com/users/Admin@org2.example.com/msp
    export CORE_PEER_ADDRESS=localhost:9051
}

# Set environment for Org3 (optional)
setGlobalsForOrg3() {
    export CORE_PEER_LOCALMSPID="Org3MSP"
    export CORE_PEER_TLS_ROOTCERT_FILE=$PWD/organizations/peerOrganizations/org3.example.com/peers/peer0.org3.example.com/tls/ca.crt
    export CORE_PEER_MSPCONFIGPATH=$PWD/organizations/peerOrganizations/org3.example.com/users/Admin@org3.example.com/msp
    export CORE_PEER_ADDRESS=localhost:11051
}

packageChaincode() {
    echo -e "${GREEN}Packaging chaincode...${NC}"

    rm -rf ${CC_NAME}.tar.gz

    setGlobalsForOrg1

    if [ "$CC_SRC_LANGUAGE" = "golang" ]; then
        CC_RUNTIME_LANGUAGE=golang
    elif [ "$CC_SRC_LANGUAGE" = "javascript" ]; then
        CC_RUNTIME_LANGUAGE=node
    elif [ "$CC_SRC_LANGUAGE" = "typescript" ]; then
        CC_RUNTIME_LANGUAGE=node
    elif [ "$CC_SRC_LANGUAGE" = "java" ]; then
        CC_RUNTIME_LANGUAGE=java
    else
        echo -e "${RED}Unsupported chaincode language: ${CC_SRC_LANGUAGE}${NC}"
        exit 1
    fi

    peer lifecycle chaincode package ${CC_NAME}.tar.gz \
        --path ${CC_SRC_PATH} \
        --lang ${CC_RUNTIME_LANGUAGE} \
        --label ${CC_NAME}_${CC_VERSION}

    echo -e "${GREEN}Chaincode packaged: ${CC_NAME}.tar.gz${NC}"
}

installChaincode() {
    # Helper to get package ID for current peer
    get_pkg_id() {
        peer lifecycle chaincode queryinstalled > log.txt || true
        sed -n "/${CC_NAME}_${CC_VERSION}/{s/^Package ID: //; s/, Label:.*$//; p;}" log.txt
    }

    # Org1
    echo -e "${GREEN}Checking/installing chaincode on Org1 Peer0...${NC}"
    setGlobalsForOrg1
    PID_ORG1=$(get_pkg_id)
    if [ -z "$PID_ORG1" ]; then
        peer lifecycle chaincode install ${CC_NAME}.tar.gz || true
        PID_ORG1=$(get_pkg_id)
    else
        echo -e "${YELLOW}Org1 already has package ${PID_ORG1}; skipping install${NC}"
    fi

    # Org2
    echo -e "${GREEN}Checking/installing chaincode on Org2 Peer0...${NC}"
    setGlobalsForOrg2
    PID_ORG2=$(get_pkg_id)
    if [ -z "$PID_ORG2" ]; then
        peer lifecycle chaincode install ${CC_NAME}.tar.gz || true
        PID_ORG2=$(get_pkg_id)
    else
        echo -e "${YELLOW}Org2 already has package ${PID_ORG2}; skipping install${NC}"
    fi

    # Org3 (optional)
    if [ -d "$PWD/organizations/peerOrganizations/org3.example.com" ]; then
        echo -e "${GREEN}Checking/installing chaincode on Org3 Peer0...${NC}"
        setGlobalsForOrg3
        PID_ORG3=$(get_pkg_id)
        if [ -z "$PID_ORG3" ]; then
            peer lifecycle chaincode install ${CC_NAME}.tar.gz || true
            PID_ORG3=$(get_pkg_id)
        else
            echo -e "${YELLOW}Org3 already has package ${PID_ORG3}; skipping install${NC}"
        fi
    fi

    # Ensure PACKAGE_ID is set for subsequent steps (use any org's value)
    PACKAGE_ID=${PID_ORG1:-${PID_ORG2:-${PID_ORG3:-""}}}
    if [ -z "$PACKAGE_ID" ]; then
        echo -e "${RED}Failed to determine PACKAGE_ID after install checks${NC}"
        exit 1
    fi

    echo -e "${GREEN}Chaincode install step completed. PACKAGE_ID=${PACKAGE_ID}${NC}"
}

queryInstalled() {
    setGlobalsForOrg1
    peer lifecycle chaincode queryinstalled >&log.txt
    cat log.txt
    PACKAGE_ID=$(sed -n "/${CC_NAME}_${CC_VERSION}/{s/^Package ID: //; s/, Label:.*$//; p;}" log.txt)
    echo "PackageID is ${PACKAGE_ID}"
}

approveForMyOrg1() {
    setGlobalsForOrg1

    if [ -z "$PACKAGE_ID" ]; then
        queryInstalled
    fi

    echo -e "${GREEN}Approving chaincode for Org1...${NC}"

    peer lifecycle chaincode approveformyorg \
        -o localhost:7050 \
        --ordererTLSHostnameOverride orderer.example.com \
        --tls --cafile $PWD/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/msp/tlscacerts/tlsca.example.com-cert.pem \
        --channelID $CHANNEL_NAME \
        --name ${CC_NAME} \
        --version ${CC_VERSION} \
        --package-id ${PACKAGE_ID} \
        --sequence ${CC_SEQUENCE}

    echo -e "${GREEN}Chaincode approved for Org1${NC}"
}

approveForMyOrg2() {
    setGlobalsForOrg2

    if [ -z "$PACKAGE_ID" ]; then
        queryInstalled
    fi

    echo -e "${GREEN}Approving chaincode for Org2...${NC}"

    peer lifecycle chaincode approveformyorg \
        -o localhost:7050 \
        --ordererTLSHostnameOverride orderer.example.com \
        --tls --cafile $PWD/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/msp/tlscacerts/tlsca.example.com-cert.pem \
        --channelID $CHANNEL_NAME \
        --name ${CC_NAME} \
        --version ${CC_VERSION} \
        --package-id ${PACKAGE_ID} \
        --sequence ${CC_SEQUENCE}

    echo -e "${GREEN}Chaincode approved for Org2${NC}"
}

approveForMyOrg3() {
    if [ ! -d "$PWD/organizations/peerOrganizations/org3.example.com" ]; then
        return
    fi

    setGlobalsForOrg3

    if [ -z "$PACKAGE_ID" ]; then
        queryInstalled
    fi

    echo -e "${GREEN}Approving chaincode for Org3...${NC}"

    peer lifecycle chaincode approveformyorg \
        -o localhost:7050 \
        --ordererTLSHostnameOverride orderer.example.com \
        --tls --cafile $PWD/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/msp/tlscacerts/tlsca.example.com-cert.pem \
        --channelID $CHANNEL_NAME \
        --name ${CC_NAME} \
        --version ${CC_VERSION} \
        --package-id ${PACKAGE_ID} \
        --sequence ${CC_SEQUENCE} || true

    echo -e "${GREEN}Chaincode approved for Org3 (if present)${NC}"
}

checkCommitReadiness() {
    setGlobalsForOrg1

    echo -e "${YELLOW}Checking commit readiness...${NC}"

    peer lifecycle chaincode checkcommitreadiness \
        --channelID $CHANNEL_NAME \
        --name ${CC_NAME} \
        --version ${CC_VERSION} \
        --sequence ${CC_SEQUENCE} \
        --output json
}

commitChaincodeDefinition() {
    setGlobalsForOrg1

    echo -e "${GREEN}Committing chaincode definition...${NC}"

    peer lifecycle chaincode commit \
        -o localhost:7050 \
        --ordererTLSHostnameOverride orderer.example.com \
        --tls --cafile $PWD/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/msp/tlscacerts/tlsca.example.com-cert.pem \
        --channelID $CHANNEL_NAME \
        --name ${CC_NAME} \
        --version ${CC_VERSION} \
        --sequence ${CC_SEQUENCE} \
        --peerAddresses localhost:7051 \
        --tlsRootCertFiles $PWD/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt \
        --peerAddresses localhost:9051 \
        --tlsRootCertFiles $PWD/organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/tls/ca.crt

    echo -e "${GREEN}Chaincode definition committed${NC}"
}

queryCommitted() {
    setGlobalsForOrg1

    echo -e "${YELLOW}Querying committed chaincodes...${NC}"

    peer lifecycle chaincode querycommitted \
        --channelID $CHANNEL_NAME \
        --name ${CC_NAME}
}

chaincodeInvokeInit() {
    setGlobalsForOrg1

    echo -e "${GREEN}Invoking chaincode init function...${NC}"

    peer chaincode invoke \
        -o localhost:7050 \
        --ordererTLSHostnameOverride orderer.example.com \
        --tls --cafile $PWD/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/msp/tlscacerts/tlsca.example.com-cert.pem \
        -C $CHANNEL_NAME \
        -n ${CC_NAME} \
        --peerAddresses localhost:7051 \
        --tlsRootCertFiles $PWD/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt \
        --peerAddresses localhost:9051 \
        --tlsRootCertFiles $PWD/organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/tls/ca.crt \
        -c '{"function":"InitLedger","Args":[]}'

    echo -e "${GREEN}Chaincode initialized${NC}"
}

# Main execution
# Add local bin and Go to PATH
export PATH=${PWD}/bin:/usr/local/go/bin:$PATH
export FABRIC_CFG_PATH=$PWD/config
export CORE_PEER_TLS_ENABLED=true

echo "Executing chaincode deployment with the following parameters:"
echo "- Channel name: ${CHANNEL_NAME}"
echo "- Chaincode name: ${CC_NAME}"
echo "- Chaincode version: ${CC_VERSION}"
echo "- Chaincode path: ${CC_SRC_PATH}"
echo "- Chaincode language: ${CC_SRC_LANGUAGE}"
echo "- Sequence: ${CC_SEQUENCE}"

packageChaincode
installChaincode
queryInstalled
approveForMyOrg1
approveForMyOrg2
approveForMyOrg3
checkCommitReadiness
commitChaincodeDefinition
queryCommitted

if [ "$CC_INIT_FCN" != "NA" ]; then
    chaincodeInvokeInit
fi

echo -e "${GREEN}Chaincode deployment completed successfully!${NC}"
