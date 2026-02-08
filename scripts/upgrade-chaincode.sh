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
CC_NAME=basic
CHANNEL_NAME=mychannel
PACKAGE_ID="basic_${VERSION}:e8675f33d57cf721a3201322622bbf564c48ea45e991cc1bcbf63551a456f8fc"

echo "========================================="
echo "Upgrading Chaincode"
echo "========================================="
echo "Version: $VERSION"
echo "Sequence: $SEQUENCE"
echo "Package ID: $PACKAGE_ID"
echo ""

# Set Fabric config path
export FABRIC_CFG_PATH=${PWD}/config

# Set environment for Org1
export CORE_PEER_TLS_ENABLED=true
export CORE_PEER_LOCALMSPID="Org1MSP"
export CORE_PEER_TLS_ROOTCERT_FILE=${PWD}/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt
export CORE_PEER_MSPCONFIGPATH=${PWD}/organizations/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp
export CORE_PEER_ADDRESS=localhost:7051

echo "Approving chaincode for Org1..."
./bin/peer lifecycle chaincode approveformyorg \
  -o localhost:7050 \
  --ordererTLSHostnameOverride orderer.example.com \
  --channelID $CHANNEL_NAME \
  --name $CC_NAME \
  --version $VERSION \
  --package-id $PACKAGE_ID \
  --sequence $SEQUENCE \
  --tls \
  --cafile ${PWD}/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/msp/tlscacerts/tlsca.example.com-cert.pem

echo "✓ Org1 approved"
echo ""

# Set environment for Org2
export CORE_PEER_LOCALMSPID="Org2MSP"
export CORE_PEER_TLS_ROOTCERT_FILE=${PWD}/organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/tls/ca.crt
export CORE_PEER_MSPCONFIGPATH=${PWD}/organizations/peerOrganizations/org2.example.com/users/Admin@org2.example.com/msp
export CORE_PEER_ADDRESS=localhost:9051

echo "Approving chaincode for Org2..."
./bin/peer lifecycle chaincode approveformyorg \
  -o localhost:7050 \
  --ordererTLSHostnameOverride orderer.example.com \
  --channelID $CHANNEL_NAME \
  --name $CC_NAME \
  --version $VERSION \
  --package-id $PACKAGE_ID \
  --sequence $SEQUENCE \
  --tls \
  --cafile ${PWD}/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/msp/tlscacerts/tlsca.example.com-cert.pem

echo "✓ Org2 approved"
echo ""

echo "Checking commit readiness..."
./bin/peer lifecycle chaincode checkcommitreadiness \
  --channelID $CHANNEL_NAME \
  --name $CC_NAME \
  --version $VERSION \
  --sequence $SEQUENCE \
  --tls \
  --cafile ${PWD}/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/msp/tlscacerts/tlsca.example.com-cert.pem \
  --output json

echo ""
echo "Committing chaincode definition..."
./bin/peer lifecycle chaincode commit \
  -o localhost:7050 \
  --ordererTLSHostnameOverride orderer.example.com \
  --channelID $CHANNEL_NAME \
  --name $CC_NAME \
  --version $VERSION \
  --sequence $SEQUENCE \
  --tls \
  --cafile ${PWD}/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/msp/tlscacerts/tlsca.example.com-cert.pem \
  --peerAddresses localhost:7051 \
  --tlsRootCertFiles ${PWD}/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt \
  --peerAddresses localhost:9051 \
  --tlsRootCertFiles ${PWD}/organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/tls/ca.crt

echo ""
echo "✓ Chaincode committed successfully!"
echo ""
echo "Querying committed chaincode..."
./bin/peer lifecycle chaincode querycommitted --channelID $CHANNEL_NAME --name $CC_NAME

echo ""
echo "========================================="
echo "Chaincode upgrade completed!"
echo "========================================="
