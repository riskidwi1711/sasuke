#!/bin/bash
set -euo pipefail
#
# Upgrade Chaincode Script
# Usage: ./upgrade-chaincode.sh <version> <sequence>
#
# Example: ./upgrade-chaincode.sh 3.0 2
#

set -e

VERSION=${1:-2.0}
SEQUENCE=${2:-2}
CC_NAME=${3:-asset-contract}
CHANNEL_NAME=${4:-mychannel}

# Add local bin to PATH
export PATH=${PWD}/bin:$PATH
export FABRIC_CFG_PATH=${PWD}/config

echo "========================================="
echo "Upgrading Chaincode"
echo "========================================="
echo "Chaincode: $CC_NAME"
echo "Version: $VERSION"
echo "Sequence: $SEQUENCE"
echo "Channel: $CHANNEL_NAME"
echo ""

# Set environment for Org1 to query installed chaincodes
export CORE_PEER_TLS_ENABLED=true
export CORE_PEER_LOCALMSPID="Org1MSP"
export CORE_PEER_TLS_ROOTCERT_FILE=${PWD}/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt
export CORE_PEER_MSPCONFIGPATH=${PWD}/organizations/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp
export CORE_PEER_ADDRESS=localhost:7051

# Dynamically resolve PACKAGE_ID from installed chaincodes
echo "Querying installed chaincodes to resolve PACKAGE_ID..."
PACKAGE_ID=$(peer lifecycle chaincode queryinstalled --output json | \
    jq -r --arg label "${CC_NAME}_${VERSION}" \
    '.installed_chaincodes[] | select(.label == $label) | .package_id')

if [ -z "$PACKAGE_ID" ]; then
    echo "ERROR: No installed chaincode found with label '${CC_NAME}_${VERSION}'"
    echo "Installed chaincodes:"
    peer lifecycle chaincode queryinstalled
    exit 1
fi

echo "Resolved PACKAGE_ID: $PACKAGE_ID"
echo ""

ORDERER_CA=${PWD}/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/msp/tlscacerts/tlsca.example.com-cert.pem

echo "Approving chaincode for Org1..."
peer lifecycle chaincode approveformyorg \
  -o localhost:7050 \
  --ordererTLSHostnameOverride orderer.example.com \
  --channelID $CHANNEL_NAME \
  --name $CC_NAME \
  --version $VERSION \
  --package-id $PACKAGE_ID \
  --sequence $SEQUENCE \
  --tls \
  --cafile "$ORDERER_CA"

echo "Org1 approved"
echo ""

# Set environment for Org2
export CORE_PEER_LOCALMSPID="Org2MSP"
export CORE_PEER_TLS_ROOTCERT_FILE=${PWD}/organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/tls/ca.crt
export CORE_PEER_MSPCONFIGPATH=${PWD}/organizations/peerOrganizations/org2.example.com/users/Admin@org2.example.com/msp
export CORE_PEER_ADDRESS=localhost:9051

echo "Approving chaincode for Org2..."
peer lifecycle chaincode approveformyorg \
  -o localhost:7050 \
  --ordererTLSHostnameOverride orderer.example.com \
  --channelID $CHANNEL_NAME \
  --name $CC_NAME \
  --version $VERSION \
  --package-id $PACKAGE_ID \
  --sequence $SEQUENCE \
  --tls \
  --cafile "$ORDERER_CA"

echo "Org2 approved"
echo ""

# Approve for Org3 if it exists
if [ -d "${PWD}/organizations/peerOrganizations/org3.example.com" ]; then
    export CORE_PEER_LOCALMSPID="Org3MSP"
    export CORE_PEER_TLS_ROOTCERT_FILE=${PWD}/organizations/peerOrganizations/org3.example.com/peers/peer0.org3.example.com/tls/ca.crt
    export CORE_PEER_MSPCONFIGPATH=${PWD}/organizations/peerOrganizations/org3.example.com/users/Admin@org3.example.com/msp
    export CORE_PEER_ADDRESS=localhost:11051

    echo "Approving chaincode for Org3..."
    peer lifecycle chaincode approveformyorg \
      -o localhost:7050 \
      --ordererTLSHostnameOverride orderer.example.com \
      --channelID $CHANNEL_NAME \
      --name $CC_NAME \
      --version $VERSION \
      --package-id $PACKAGE_ID \
      --sequence $SEQUENCE \
      --tls \
      --cafile "$ORDERER_CA" || echo "Org3 approval skipped (may not be in channel config)"

    echo ""
fi

echo "Checking commit readiness..."
peer lifecycle chaincode checkcommitreadiness \
  --channelID $CHANNEL_NAME \
  --name $CC_NAME \
  --version $VERSION \
  --sequence $SEQUENCE \
  --tls \
  --cafile "$ORDERER_CA" \
  --output json

echo ""

# Build commit command with all available peer addresses
COMMIT_ARGS=(
  -o localhost:7050
  --ordererTLSHostnameOverride orderer.example.com
  --channelID $CHANNEL_NAME
  --name $CC_NAME
  --version $VERSION
  --sequence $SEQUENCE
  --tls
  --cafile "$ORDERER_CA"
  --peerAddresses localhost:7051
  --tlsRootCertFiles ${PWD}/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt
  --peerAddresses localhost:9051
  --tlsRootCertFiles ${PWD}/organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/tls/ca.crt
)

if [ -d "${PWD}/organizations/peerOrganizations/org3.example.com" ]; then
    COMMIT_ARGS+=(
      --peerAddresses localhost:11051
      --tlsRootCertFiles ${PWD}/organizations/peerOrganizations/org3.example.com/peers/peer0.org3.example.com/tls/ca.crt
    )
fi

echo "Committing chaincode definition..."
peer lifecycle chaincode commit "${COMMIT_ARGS[@]}"

echo ""
echo "Chaincode committed successfully!"
echo ""
echo "Querying committed chaincode..."
peer lifecycle chaincode querycommitted --channelID $CHANNEL_NAME --name $CC_NAME

echo ""
echo "========================================="
echo "Chaincode upgrade completed!"
echo "========================================="
