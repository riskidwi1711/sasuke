package main

import (
    "log"
    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

func main() {
    chaincode, err := contractapi.NewChaincode(new(AssetContract))
    if err != nil {
        log.Panicf("Error creating asset-contract: %v", err)
    }

    if err := chaincode.Start(); err != nil {
        log.Panicf("Error starting asset-contract: %v", err)
    }
}

