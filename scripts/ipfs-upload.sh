#!/bin/bash

# IPFS File Upload Helper Script
IPFS_HOST=${IPFS_HOST:-"localhost"}
IPFS_PORT=${IPFS_PORT:-"5001"}

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

function printHelp() {
    echo "Usage: "
    echo "  ipfs-upload.sh <command> [options]"
    echo "    <command> - one of 'add', 'get', 'cat', 'pin', 'ls'"
    echo "      - 'add <file>' - add file to IPFS"
    echo "      - 'get <hash>' - get file from IPFS"
    echo "      - 'cat <hash>' - display file content"
    echo "      - 'pin <hash>' - pin file to keep it"
    echo "      - 'ls <hash>' - list directory contents"
    echo
    echo "  Example:"
    echo "    ipfs-upload.sh add myfile.txt"
    echo "    ipfs-upload.sh cat QmHash..."
}

function addFile() {
    local file=$1

    if [ ! -f "$file" ]; then
        echo -e "${RED}File not found: $file${NC}"
        exit 1
    fi

    echo -e "${GREEN}Uploading file to IPFS...${NC}"
    result=$(curl -s -X POST -F file=@"$file" "http://${IPFS_HOST}:${IPFS_PORT}/api/v0/add")

    hash=$(echo $result | grep -o '"Hash":"[^"]*' | cut -d'"' -f4)

    if [ -z "$hash" ]; then
        echo -e "${RED}Failed to upload file${NC}"
        echo $result
        exit 1
    fi

    echo -e "${GREEN}File uploaded successfully!${NC}"
    echo "IPFS Hash: $hash"
    echo "Gateway URL: http://${IPFS_HOST}:8080/ipfs/$hash"

    # Auto-pin the file
    pinFile $hash

    return 0
}

function getFile() {
    local hash=$1
    local output=${2:-"downloaded_file"}

    echo -e "${GREEN}Downloading file from IPFS...${NC}"
    curl -s -X POST "http://${IPFS_HOST}:${IPFS_PORT}/api/v0/get?arg=$hash" -o "$output"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}File downloaded: $output${NC}"
    else
        echo -e "${RED}Failed to download file${NC}"
        exit 1
    fi
}

function catFile() {
    local hash=$1

    echo -e "${GREEN}Fetching file content...${NC}"
    curl -s -X POST "http://${IPFS_HOST}:${IPFS_PORT}/api/v0/cat?arg=$hash"
}

function pinFile() {
    local hash=$1

    echo -e "${YELLOW}Pinning file to IPFS...${NC}"
    result=$(curl -s -X POST "http://${IPFS_HOST}:${IPFS_PORT}/api/v0/pin/add?arg=$hash")

    if echo $result | grep -q "Pins"; then
        echo -e "${GREEN}File pinned successfully${NC}"
    else
        echo -e "${RED}Failed to pin file${NC}"
    fi
}

function lsDirectory() {
    local hash=$1

    echo -e "${GREEN}Listing directory contents...${NC}"
    curl -s -X POST "http://${IPFS_HOST}:${IPFS_PORT}/api/v0/ls?arg=$hash" | jq '.'
}

# Main execution
COMMAND=$1
shift

case $COMMAND in
    add)
        addFile $1
        ;;
    get)
        getFile $1 $2
        ;;
    cat)
        catFile $1
        ;;
    pin)
        pinFile $1
        ;;
    ls)
        lsDirectory $1
        ;;
    *)
        printHelp
        exit 1
        ;;
esac
