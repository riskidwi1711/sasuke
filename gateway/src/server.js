const express = require('express');
const cors = require('cors');
const dotenv = require('dotenv');
dotenv.config();

const { getContractForMSP, getContractForMSPAndCC } = require('./gateway');
let protos;
try { protos = require('@hyperledger/fabric-protos'); } catch { protos = null; }

const app = express();
app.use(cors());
app.use(express.json({ limit: '1mb' }));

app.get('/health', (req, res) => {
  res.json({ status: 'ok' });
});

// Generic evaluate (query)
app.post('/api/evaluate', async (req, res) => {
  try {
    const { function: fn, args = [], target } = req.body || {};
    if (!fn) return res.status(400).json({ error: 'function is required' });
    const msp = resolveMSP(req);
    const cc = target && typeof target === 'string' ? target : process.env.FABRIC_CHAINCODE;
    const contract = await getContractForMSPAndCC(msp, cc);
    const result = await contract.evaluateTransaction(fn, ...args);
    // try parse JSON
    let payload;
    try { payload = JSON.parse(result.toString('utf8')); } catch { payload = result.toString('utf8'); }
    res.json({ ok: true, result: payload });
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message });
  }
});

// Generic submit (transaction)
app.post('/api/submit', async (req, res) => {
  try {
    const { function: fn, args = [] } = req.body || {};
    if (!fn) return res.status(400).json({ error: 'function is required' });
    const msp = resolveMSP(req);
    const contract = await getContractForMSP(msp);
    const tx = contract.createTransaction(fn);
    const txId = tx.getTransactionId();
    const result = await tx.submit(...args);
    let payload;
    try { payload = JSON.parse(result.toString('utf8')); } catch { payload = result.toString('utf8'); }
    // fabric-network waits for commit by default if using the default commit handler; if this succeeds, we mark committed
    res.json({ ok: true, txId, committed: true, result: payload });
  } catch (err) {
    res.status(500).json({ ok: false, committed: false, error: err.message });
  }
});

// Shortcuts
app.get('/api/assets', async (req, res) => {
  try {
    const msp = resolveMSP(req);
    const contract = await getContractForMSP(msp);
    const result = await contract.evaluateTransaction('GetAllAssets');
    const data = JSON.parse(result.toString('utf8'));
    res.json({ ok: true, assets: data });
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message });
  }
});

app.get('/api/assets/:id', async (req, res) => {
  try {
    const msp = resolveMSP(req);
    const contract = await getContractForMSP(msp);
    const result = await contract.evaluateTransaction('GetAsset', req.params.id);
    const data = JSON.parse(result.toString('utf8'));
    res.json({ ok: true, asset: data });
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message });
  }
});

// QSCC endpoints (read-only)
app.get('/api/network/chaininfo', async (req, res) => {
  try {
    const msp = resolveMSP(req);
    const contract = await getContractForMSPAndCC(msp, 'qscc');
    const channel = process.env.FABRIC_CHANNEL;
    const buf = await contract.evaluateTransaction('GetChainInfo', channel);
    if (protos && protos.common && protos.common.BlockchainInfo && protos.common.BlockchainInfo.decode) {
      const info = protos.common.BlockchainInfo.decode(buf);
      const toHex = (b) => (b && b.length ? Buffer.from(b).toString('hex') : '');
      res.json({ ok: true, height: info.height ? info.height.toString() : undefined, currentBlockHash: toHex(info.currentBlockHash), previousBlockHash: toHex(info.previousBlockHash) });
    } else {
      res.json({ ok: true, base64: buf.toString('base64') });
    }
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message });
  }
});

app.get('/api/network/block/:num', async (req, res) => {
  try {
    const msp = resolveMSP(req);
    const contract = await getContractForMSPAndCC(msp, 'qscc');
    const channel = process.env.FABRIC_CHANNEL;
    const buf = await contract.evaluateTransaction('GetBlockByNumber', channel, String(req.params.num));
    if (protos && protos.common && protos.common.Block && protos.common.Block.decode) {
      const block = protos.common.Block.decode(buf);
      const number = block.header && block.header.number ? block.header.number.toString() : String(req.params.num);
      const txs = [];
      try {
        const envs = block.data.data || [];
        for (const env of envs) {
          const payload = protos.common.Payload.decode(env.payload);
          const chdr = protos.common.ChannelHeader.decode(payload.header.channel_header);
          txs.push({ txId: chdr.tx_id, timestamp: chdr.timestamp, type: chdr.typeString || chdr.type });
        }
      } catch (_) {}
      res.json({ ok: true, block: { number, txCount: txs.length, txs } });
    } else {
      res.json({ ok: true, base64: buf.toString('base64') });
    }
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message });
  }
});

app.get('/api/network/tx/:txId', async (req, res) => {
  try {
    const msp = resolveMSP(req);
    const contract = await getContractForMSPAndCC(msp, 'qscc');
    const channel = process.env.FABRIC_CHANNEL;
    const buf = await contract.evaluateTransaction('GetTransactionByID', channel, req.params.txId);
    if (protos && protos.protos && protos.protos.ProcessedTransaction && protos.protos.ProcessedTransaction.decode) {
      const ptx = protos.protos.ProcessedTransaction.decode(buf);
      let txId = req.params.txId, timestamp = undefined, validationCode = undefined;
      try {
        const payload = protos.common.Payload.decode(ptx.transactionEnvelope.payload);
        const chdr = protos.common.ChannelHeader.decode(payload.header.channel_header);
        txId = chdr.tx_id; timestamp = chdr.timestamp;
        validationCode = ptx.validationCode;
      } catch (_) {}
      res.json({ ok: true, tx: { txId, timestamp, validationCode } });
    } else {
      res.json({ ok: true, base64: buf.toString('base64') });
    }
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message });
  }
});

app.get('/api/network/blockByTx/:txId', async (req, res) => {
  try {
    const msp = resolveMSP(req);
    const contract = await getContractForMSPAndCC(msp, 'qscc');
    const channel = process.env.FABRIC_CHANNEL;
    const buf = await contract.evaluateTransaction('GetBlockByTxID', channel, req.params.txId);
    if (protos && protos.common && protos.common.Block && protos.common.Block.decode) {
      const block = protos.common.Block.decode(buf);
      const number = block.header && block.header.number ? block.header.number.toString() : undefined;
      res.json({ ok: true, blockNumber: number });
    } else {
      res.json({ ok: true, base64: buf.toString('base64') });
    }
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message });
  }
});

// Explorer summary: peers/orderer, height, last blocks, recent asset events
app.get('/api/explorer/summary', async (req, res) => {
  try {
    const msp = resolveMSP(req);
    const limit = Math.max(1, Math.min(parseInt(String(req.query.limit || '10')), 50));
    const blocks = Math.max(1, Math.min(parseInt(String(req.query.blocks || '5')), 20));

    // Load CCP to count peers/orderers
    const mspId = msp;
    const ccpPathEnv = `FABRIC_ORG_${mspId}_CCP_PATH`;
    const ccpPath = process.env[ccpPathEnv];
    let peersCount = undefined, orderersCount = undefined, org = mspId;
    try {
      if (ccpPath) {
        const fs = require('fs');
        const ccp = JSON.parse(fs.readFileSync(ccpPath, 'utf8'));
        peersCount = ccp.peers ? Object.keys(ccp.peers).length : undefined;
        orderersCount = ccp.orderers ? Object.keys(ccp.orderers).length : 1;
        org = (ccp.organizations && Object.keys(ccp.organizations)[0]) || mspId;
      }
    } catch (_) {}

    // Chain height
    const qscc = await getContractForMSPAndCC(msp, 'qscc');
    const channel = process.env.FABRIC_CHANNEL;
    const infoBuf = await qscc.evaluateTransaction('GetChainInfo', channel);
    let height = undefined;
    if (protos && protos.common && protos.common.BlockchainInfo && protos.common.BlockchainInfo.decode) {
      const info = protos.common.BlockchainInfo.decode(infoBuf);
      height = info.height ? info.height.toString() : undefined;
    }

    // Latest blocks
    const latestBlocks = [];
    const hNum = height ? parseInt(height) : 0;
    const start = hNum > 0 ? hNum - 1 : 0;
    const min = start >= (blocks - 1) ? start - (blocks - 1) : 0;
    for (let n = start; n >= min; n--) {
      try {
        const bbuf = await qscc.evaluateTransaction('GetBlockByNumber', channel, String(n));
        if (protos && protos.common && protos.common.Block && protos.common.Block.decode) {
          const block = protos.common.Block.decode(bbuf);
          const number = block.header && block.header.number ? block.header.number.toString() : String(n);
          const txs = [];
          try {
            const envs = block.data.data || [];
            for (const env of envs) {
              const payload = protos.common.Payload.decode(env.payload);
              const chdr = protos.common.ChannelHeader.decode(payload.header.channel_header);
              txs.push({ txId: chdr.tx_id, timestamp: chdr.timestamp, type: chdr.typeString || chdr.type });
            }
          } catch (_) {}
          latestBlocks.push({ number, txCount: txs.length, txs });
        }
      } catch (_) {}
    }

    // Recent asset events (collect across assets, limited)
    const appCC = await getContractForMSP(msp);
    let assets = [];
    try {
      const abuf = await appCC.evaluateTransaction('GetAllAssets');
      assets = JSON.parse(abuf.toString('utf8')) || [];
    } catch (_) {}
    const events = [];
    for (const a of assets) {
      if (!a || !a.assetId) continue;
      try {
        const hbuf = await appCC.evaluateTransaction('GetAssetHistory', a.assetId);
        const hist = JSON.parse(hbuf.toString('utf8')) || [];
        for (const ev of hist) {
          if (!ev || !ev.txId) continue; // skip state-only entries without txId
          const assetId = a.assetId;
          const kind = (ev.kind || '').toLowerCase();
          events.push({ txId: ev.txId, kind, assetId, date: ev.date });
        }
      } catch (_) {}
    }
    // sort by date desc, limit
    events.sort((x, y) => String(y.date).localeCompare(String(x.date)));
    const limited = events.slice(0, limit);
    // enrich with block numbers via QSCC
    for (const ev of limited) {
      try {
        const btx = await qscc.evaluateTransaction('GetBlockByTxID', channel, ev.txId);
        if (protos && protos.common && protos.common.Block && protos.common.Block.decode) {
          const block = protos.common.Block.decode(btx);
          ev.blockNumber = block.header && block.header.number ? block.header.number.toString() : undefined;
        }
      } catch (_) {}
    }

    res.json({ ok: true, network: { org, peers: peersCount, orderers: orderersCount, height }, latestBlocks, recentEvents: limited });
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message });
  }
});

const port = process.env.PORT || 3000;
function resolveMSP(req) {
  // Priority: explicit MSP header → role header mapping → env default (admin→Org1MSP, user→Org2MSP)
  const hMSP = req.header('x-fabric-msp');
  if (hMSP) return hMSP;
  const role = (req.header('x-fabric-role') || '').toLowerCase();
  if (role) {
    if (role === 'admin') return process.env.FABRIC_ROLE_ADMIN_MSP || 'Org1MSP';
    if (role === 'user') return process.env.FABRIC_ROLE_USER_MSP || 'Org2MSP';
  }
  // fallback to admin mapping
  return process.env.FABRIC_ROLE_ADMIN_MSP || 'Org1MSP';
}

app.listen(port, () => {
  // eslint-disable-next-line no-console
  console.log(`Fabric Gateway API listening on port ${port}`);
});
