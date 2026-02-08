#!/bin/bash

# Initialize IPFS if not already initialized
if [ ! -d "/data/ipfs/config" ]; then
    echo "Initializing IPFS node..."
    ipfs init --profile=server

    # Configure IPFS
    ipfs config Addresses.API /ip4/0.0.0.0/tcp/5001
    ipfs config Addresses.Gateway /ip4/0.0.0.0/tcp/8080
    ipfs config --json API.HTTPHeaders.Access-Control-Allow-Origin '["*"]'
    ipfs config --json API.HTTPHeaders.Access-Control-Allow-Methods '["PUT", "POST", "GET"]'

    # Enable experimental features
    ipfs config --json Experimental.FilestoreEnabled true
    ipfs config --json Experimental.UrlstoreEnabled true
    ipfs config --json Experimental.ShardingEnabled true
    ipfs config --json Experimental.Libp2pStreamMounting true

    echo "IPFS initialized successfully"
else
    echo "IPFS already initialized"
fi

# Start IPFS daemon
exec ipfs daemon --migrate=true --enable-gc
