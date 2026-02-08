# Hyperledger Fabric Network Setup with IPFS and Explorer

Setup lengkap dan customizable untuk Hyperledger Fabric dengan integrasi IPFS dan Hyperledger Explorer.

## Fitur

- **Fabric Network**: 2 Organisasi dengan 2 Peer masing-masing
- **IPFS Integration**: Penyimpanan terdistribusi dengan IPFS dan IPFS Cluster
- **Hyperledger Explorer**: Dashboard untuk monitoring dan explorasi blockchain
- **Automated Scripts**: Script otomatis untuk deployment dan management
- **Customizable**: Konfigurasi mudah melalui file .env

## Struktur Direktori

```
fabric-setup/
├── .env                          # Konfigurasi environment
├── README.md                     # Dokumentasi ini
├── config/
│   ├── crypto-config.yaml        # Konfigurasi crypto material
│   └── configtx.yaml             # Konfigurasi channel dan genesis block
├── docker/
│   ├── docker-compose-ca.yaml    # Certificate Authorities
│   ├── docker-compose-network.yaml # Orderer dan Peers
│   ├── docker-compose-ipfs.yaml  # IPFS nodes
│   └── docker-compose-explorer.yaml # Hyperledger Explorer
├── scripts/
│   ├── network.sh                # Script utama untuk manage network
│   ├── deployCC.sh               # Script deploy chaincode
│   └── ipfs-upload.sh            # Helper untuk IPFS operations
├── chaincode/
│   └── basic/                    # Contoh chaincode dengan IPFS support
├── explorer/                     # Konfigurasi Explorer
├── ipfs/                         # Konfigurasi IPFS
└── organizations/                # Crypto material (generated)
```

## Prerequisites

Pastikan sudah terinstall:

- Docker & Docker Compose
- Hyperledger Fabric Binaries (cryptogen, configtxgen, peer, osnadmin)
- Node.js (untuk chaincode JavaScript)
- curl, jq (untuk IPFS scripts)

### Install Fabric Binaries

```bash
curl -sSL https://bit.ly/2ysbOFE | bash -s -- 2.5.0 1.5.5
export PATH=$PWD/bin:$PATH
```

## Quick Start

### 1. Generate Crypto Material

```bash
./scripts/network.sh generate
```

### 2. Start Network

Start network lengkap dengan CA, IPFS, Explorer, dan OCR:

```bash
./scripts/network.sh up -ca -ipfs -explorer -ocr
```

Atau start hanya Fabric network:

```bash
./scripts/network.sh up
```

### 3. Create Channel

```bash
./scripts/network.sh createChannel
```

### 4. Join Channel

```bash
./scripts/network.sh joinChannel
```

### 5. Deploy Chaincode

```bash
./scripts/network.sh deployCC -ccn basic -ccv 1.0 -ccp ./chaincode/basic -ccl javascript
```

### 6. Test Chaincode

```bash
# Set environment untuk Org1
export CORE_PEER_TLS_ENABLED=true
export CORE_PEER_LOCALMSPID="Org1MSP"
export CORE_PEER_TLS_ROOTCERT_FILE=${PWD}/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt
export CORE_PEER_MSPCONFIGPATH=${PWD}/organizations/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp
export CORE_PEER_ADDRESS=localhost:7051
export FABRIC_CFG_PATH=${PWD}/config

# Query all assets
peer chaincode query -C mychannel -n basic -c '{"Args":["GetAllAssets"]}'

# Create new asset
peer chaincode invoke -o localhost:7050 \
  --ordererTLSHostnameOverride orderer.example.com \
  --tls --cafile ${PWD}/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/msp/tlscacerts/tlsca.example.com-cert.pem \
  -C mychannel -n basic \
  --peerAddresses localhost:7051 --tlsRootCertFiles ${PWD}/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt \
  --peerAddresses localhost:9051 --tlsRootCertFiles ${PWD}/organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/tls/ca.crt \
  -c '{"function":"CreateAsset","Args":["asset3","yellow","10","Alice","500",""]}'
```

### 7. REST API Gateway

REST API Gateway untuk berinteraksi dengan chaincode via HTTP:

```bash
cd gateway
npm install

# Start REST API server
npm run api
# Server akan berjalan di http://localhost:3000

# Initialize ledger (pertama kali)
curl -X POST http://localhost:3000/api/submit \
  -H "Content-Type: application/json" \
  -d '{"function":"InitLedger"}'

# Get all assets
curl http://localhost:3000/api/assets

# Get specific asset
curl http://localhost:3000/api/assets/asset1

# Create new asset (via generic endpoint)
curl -X POST http://localhost:3000/api/submit \
  -H "Content-Type: application/json" \
  -d '{"function":"CreateAsset","args":["asset10","green","15","Alice","550",""]}'
```

**API Endpoints:**

- `GET /health` - Health check
- `GET /api/assets` - Get all assets
- `GET /api/assets/:id` - Get asset by ID
- `POST /api/evaluate` - Generic query (recommended)
- `POST /api/submit` - Generic transaction (recommended)

Dokumentasi lengkap: [gateway/API.md](gateway/API.md)

### 8. CLI Gateway Client (Node.js)

Client CLI sederhana untuk invoke/query lewat Fabric Gateway:

```bash
cd gateway

# Evaluasi (query) semua aset
node index.js evaluate GetAllAssets

# Submit transaksi: buat aset baru
node index.js submit CreateAsset asset7 yellow 10 Alice 500 ""
```

## IPFS Integration

### Upload File ke IPFS

```bash
./scripts/ipfs-upload.sh add myfile.txt
```

Output akan menampilkan IPFS hash yang bisa disimpan di chaincode.

### Update Asset dengan IPFS Hash

```bash
peer chaincode invoke -o localhost:7050 \
  --ordererTLSHostnameOverride orderer.example.com \
  --tls --cafile ${PWD}/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/msp/tlscacerts/tlsca.example.com-cert.pem \
  -C mychannel -n basic \
  --peerAddresses localhost:7051 --tlsRootCertFiles ${PWD}/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt \
  --peerAddresses localhost:9051 --tlsRootCertFiles ${PWD}/organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/tls/ca.crt \
  -c '{"function":"UpdateAssetIPFS","Args":["asset1","QmYourIPFSHashHere"]}'
```

### Retrieve File dari IPFS

```bash
./scripts/ipfs-upload.sh get QmYourIPFSHashHere output.txt
```

### IPFS Web Gateway

Akses file melalui browser:

```
http://localhost:8080/ipfs/QmYourIPFSHashHere
```

### IPFS Web UI

IPFS menyediakan web interface untuk management dan monitoring:

```
http://localhost:5001/webui
```

Fitur Web UI:

- **Status**: Monitor node status dan statistics
- **Files**: Upload, download, dan manage files
- **Explore**: Browse IPFS merkle DAG
- **Peers**: Lihat connected peers dan network topology
- **Settings**: Konfigurasi IPFS node

Untuk akses IPFS Cluster API:

```
http://localhost:9094/id
```

## Hyperledger Explorer

Setelah network berjalan dengan flag `-explorer`, akses Explorer di:

```
http://localhost:8090
```

Login credentials:

- Username: `admin`
- Password: `adminpw`

Explorer menampilkan:

- Block dan transaction details
- Chaincode information
- Network metrics
- Peer status

## OCR Service

Service OCR berbasis FastAPI + Tesseract untuk ekstraksi teks dari gambar. Aktif jika network dijalankan dengan flag `-ocr`.

- URL: `http://localhost:${OCR_API_PORT:-7070}`
- Health check: `GET /health`
- OCR: `POST /ocr` (multipart form-data dengan field `file`)

Contoh:

```bash
# OCR file gambar (default bahasa: eng)
curl -s -X POST "http://localhost:7070/ocr" \
  -F "file=@/path/to/image.png" | jq '.'

# OCR dengan bahasa Indonesian (ind)
curl -s -X POST "http://localhost:7070/ocr?lang=ind" \
  -F "file=@/path/to/image.jpg" | jq '.'

# OCR dan simpan hasil ke IPFS (butuh IPFS aktif)
curl -s -X POST "http://localhost:7070/ocr?store=true" \
  -F "file=@/path/to/image.png" | jq '.'
```

Jika `store=true` dan IPFS aktif, respons menyertakan `ipfsHash` dan `ipfsGateway` untuk mengakses hasil teks di IPFS.

## Kustomisasi

### Mengubah Konfigurasi Network

Edit file `.env` untuk mengubah:

- Port numbers
- Organization names
- Channel name
- Chaincode settings
- IPFS ports
- Explorer settings

### Menambah Organisasi

1. Edit `config/crypto-config.yaml`
2. Tambahkan organisasi baru di section `PeerOrgs`
3. Update `config/configtx.yaml` dengan organisasi baru
4. Regenerate crypto material: `./scripts/network.sh generate`

### Menambah Peer

Edit `config/crypto-config.yaml` dan ubah `Template.Count` untuk organisasi yang ingin ditambah peer-nya.

## Network Management

### Stop Network

```bash
./scripts/network.sh down
```

Ini akan menghentikan semua container dan membersihkan volumes.

### Restart Network

```bash
./scripts/network.sh restart -ca -ipfs -explorer -ocr
```

### Check Network Status

```bash
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

### View Logs

```bash
# Logs dari peer tertentu
docker logs peer0.org1.example.com

# Logs dari orderer
docker logs orderer.example.com

# Logs dari IPFS
docker logs ipfs-node

# Logs dari Explorer
docker logs explorer
```

## Troubleshooting

### Network tidak start

```bash
# Check Docker status
docker ps -a

# Check logs
docker logs <container-name>

# Clean up dan restart
./scripts/network.sh down
./scripts/network.sh up -ca -ipfs -explorer
```

### Chaincode deployment gagal

```bash
# Check chaincode dependencies
cd chaincode/basic
npm install

# Check peer logs
docker logs peer0.org1.example.com
```

### IPFS tidak accessible

```bash
# Check IPFS status
docker logs ipfs-node

# Test IPFS API
curl http://localhost:5001/api/v0/id
```

### Explorer tidak menampilkan data

```bash
# Check Explorer logs
docker logs explorer

# Check database
docker logs explorer-db

# Restart Explorer
docker restart explorer
```

## Advanced Usage

### Multi-Host Deployment

Untuk deployment di multiple hosts, update docker-compose files dengan:

- External IP addresses
- Proper hostname resolution
- TLS certificates untuk remote access

### Production Considerations

1. **Security**:

   - Ganti default passwords
   - Enable mutual TLS
   - Implement proper key management
   - Use hardware security modules (HSM)

2. **Scalability**:

   - Add more peers
   - Use Kafka/Raft ordering service
   - Implement load balancing
   - Use CouchDB untuk rich queries

3. **Monitoring**:
   - Setup Prometheus metrics
   - Configure log aggregation
   - Implement alerting
   - Use performance monitoring tools

### Backup dan Recovery

```bash
# Backup crypto material
tar -czf crypto-backup.tar.gz organizations/

# Backup chaincode
tar -czf chaincode-backup.tar.gz chaincode/

# Backup IPFS data
docker run --rm -v ipfs-data:/data -v $(pwd):/backup alpine tar czf /backup/ipfs-backup.tar.gz -C /data .
```

## Port Reference

| Service               | Port           | Description            |
| --------------------- | -------------- | ---------------------- |
| Orderer               | 7050           | Orderer endpoint       |
| Orderer Admin         | 7053           | Orderer admin endpoint |
| Orderer Operations    | 9443           | Metrics/operations     |
| Org1 Peer0            | 7051           | Peer endpoint          |
| Org1 Peer0 Operations | 9444           | Metrics                |
| Org2 Peer0            | 9051           | Peer endpoint          |
| Org2 Peer0 Operations | 9445           | Metrics                |
| **IPFS Web UI**       | **5001/webui** | **Web dashboard**      |
| IPFS API              | 5001           | IPFS API               |
| IPFS Gateway          | 8080           | HTTP Gateway           |
| IPFS Swarm            | 4001           | P2P networking         |
| IPFS Cluster API      | 9094           | Cluster management     |
| Explorer              | 8090           | Web UI (admin/adminpw) |
| Explorer DB           | 5432           | PostgreSQL             |

## Resources

- [Hyperledger Fabric Documentation](https://hyperledger-fabric.readthedocs.io/)
- [IPFS Documentation](https://docs.ipfs.io/)
- [Hyperledger Explorer](https://github.com/hyperledger/blockchain-explorer)
- [Fabric Samples](https://github.com/hyperledger/fabric-samples)

## License

Apache-2.0

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.
