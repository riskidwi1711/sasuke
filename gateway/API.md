# Fabric Gateway REST API

Simple REST API to interact with Hyperledger Fabric chaincode.

## Setup

1) Install deps
```bash
cd hyperledger/gateway
npm install
cp .env.example .env
# edit .env to point to Org1 CCP and identity
```

2) Run API
```bash
npm run api
# http://localhost:3000
```

Required env (see .env.example):
- `FABRIC_MSP_ID` – e.g., Org1MSP
- `FABRIC_CCP_PATH` – path to connection profile JSON (Org1)
- `FABRIC_WALLET_PATH` – folder to store identities
- `FABRIC_IDENTITY` – wallet identity label to use (e.g., appUser)
- `FABRIC_CERT_PATH`, `FABRIC_KEY_PATH` – optional: auto-import identity if not in wallet
- `FABRIC_CHANNEL` – e.g., mychannel
- `FABRIC_CHAINCODE` – e.g., asset-contract
- `FABRIC_DISCOVERY_ENABLED`, `FABRIC_DISCOVERY_ASLOCALHOST` – discovery settings

## Endpoints

- GET `/health` → `{ status: 'ok' }`

- POST `/api/evaluate`
  - Body: `{ "function": "GetAllAssets", "args": [], "target": "<optional chaincode name>" }`
  - Response: `{ ok: true, result: <any> }`

- POST `/api/submit`
  - Body: `{ "function": "CreateAsset", "args": ["A-001","CAT-01","UNIT-01","LOC-01"] }`
  - Response: `{ ok: true, txId: "...", committed: true, result: <any> }`

QSCC (system chaincode) routes:
- GET `/api/network/chaininfo` → `{ ok: true, height, currentBlockHash, previousBlockHash }` (falls back to `{ base64 }` if decode not available)
- GET `/api/network/block/:num` → `{ ok: true, block: { number, txCount, txs: [{ txId, timestamp, type }] } }` (falls back to `{ base64 }`)
- GET `/api/network/tx/:txId` → `{ ok: true, tx: { txId, timestamp, validationCode } }` (falls back to `{ base64 }`)
- GET `/api/network/blockByTx/:txId` → `{ ok: true, blockNumber }` (falls back to `{ base64 }`)

Notes
- For multi-org selection, set headers: `x-fabric-msp` or `x-fabric-role`.
- If `fabric-protos` decoding is not available, responses include `base64` buffers; clients can decode via protobufs.

- GET `/api/assets`
  - Response: `{ ok: true, assets: AssetState[] }`

- GET `/api/assets/:id`
  - Response: `{ ok: true, asset: AssetState }`

Headers for multi-org
- `x-fabric-msp`: force MSP to use (e.g., Org1MSP / Org2MSP)
- `x-fabric-role`: map `admin` → `FABRIC_ROLE_ADMIN_MSP` and `user` → `FABRIC_ROLE_USER_MSP`
  - If both provided, `x-fabric-msp` takes precedence.

Notes
- `submit` waits until the transaction is committed by peers; for full commit status/txId handling, extend the implementation to listen for commit events and include `txId` in responses.
