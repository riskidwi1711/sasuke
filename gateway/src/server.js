const express = require('express');
const cors = require('cors');
const dotenv = require('dotenv');
dotenv.config();

const { getContractForMSP, getContractForMSPAndCC } = require('./gateway');
const logger = require('./logger');
const requestLogger = require('./middleware/requestLogger');
let protos;
try { protos = require('@hyperledger/fabric-protos'); } catch { protos = null; }
// Protobuf decode helpers (google-protobuf)
function asU8(buf) { return buf instanceof Uint8Array ? buf : new Uint8Array(buf); }
function getNs() {
  const P = protos || {};
  return { common: (P.common || {}), peerNs: (P.peer || P.protos || {}) };
}
function tryDeserialize(Type, buf) {
  try {
    if (!Type || !buf) return null;
    if (typeof Type.decode === 'function') return Type.decode(buf);
    if (typeof Type.deserializeBinary === 'function') return Type.deserializeBinary(asU8(buf));
  } catch (_) {}
  return null;
}

const app = express();
app.use(cors());
app.use(express.json({ limit: '1mb' }));
app.use(requestLogger);

app.get('/health', (req, res) => {
  res.json({ status: 'ok' });
});

// Generic evaluate (query)
app.post('/api/evaluate', async (req, res) => {
  const { function: fn, args = [], target } = req.body || {};
  if (!fn) return res.status(400).json({ error: 'function is required' });
  const msp = resolveMSP(req);
  const cc = target && typeof target === 'string' ? target : process.env.FABRIC_CHAINCODE;
  if (req.log) req.log.info('evaluate.call', { msp, cc, fn, argc: Array.isArray(args) ? args.length : 0 });

  // First attempt: use default discovery setting
  try {
    const contract = await getContractForMSPAndCC(msp, cc);
    const result = await contract.evaluateTransaction(fn, ...args);
    let payload;
    try { payload = JSON.parse(result.toString('utf8')); } catch { payload = result.toString('utf8'); }
    return res.json({ ok: true, result: payload });
  } catch (err) {
    const msg = (err && err.message) || '';
    // If discovery-related access is denied, retry once without discovery
    if (/DiscoveryService|access denied|discovery error/i.test(msg)) {
      if (req.log) req.log.warn('evaluate.retryNoDiscovery', { msp, cc, fn, reason: msg });
      try {
        const contract = await getContractForMSPAndCC(msp, cc, { discoveryEnabled: false });
        const result = await contract.evaluateTransaction(fn, ...args);
        let payload;
        try { payload = JSON.parse(result.toString('utf8')); } catch { payload = result.toString('utf8'); }
        return res.json({ ok: true, result: payload });
      } catch (err2) {
        if (req.log) req.log.error('evaluate.error.afterRetry', { error: err2.message });
        return res.status(500).json({ ok: false, error: err2.message });
      }
    }
    if (req.log) req.log.error('evaluate.error', { error: msg });
    return res.status(500).json({ ok: false, error: msg });
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
    if (req.log) req.log.info('submit.call', { msp, fn, argc: Array.isArray(args) ? args.length : 0, txId });
    const result = await tx.submit(...args);
    let payload;
    try { payload = JSON.parse(result.toString('utf8')); } catch { payload = result.toString('utf8'); }
    // fabric-network waits for commit by default if using the default commit handler; if this succeeds, we mark committed
    res.json({ ok: true, txId, committed: true, result: payload });
  } catch (err) {
    if (req.log) req.log.error('submit.error', { error: err.message });
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
    if (req.log) req.log.error('assets.list.error', { error: err.message });
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
    if (req.log) req.log.error('assets.get.error', { error: err.message });
    res.status(500).json({ ok: false, error: err.message });
  }
});

// QSCC endpoints (read-only)
app.get('/api/network/chaininfo', async (req, res) => {
  try {
    const msp = resolveMSP(req);
    const contract = await getContractForMSPAndCC(msp, 'qscc', { discoveryEnabled: false });
    const channel = process.env.FABRIC_CHANNEL;
    const buf = await contract.evaluateTransaction('GetChainInfo', channel);
    const { common } = getNs();
    const info = tryDeserialize(common.BlockchainInfo, buf);
    if (info) {
      const height = typeof info.getHeight === 'function' ? String(info.getHeight()) : (info.height ? String(info.height) : undefined);
      const cur = typeof info.getCurrentblockhash_asU8 === 'function' ? Buffer.from(info.getCurrentblockhash_asU8()).toString('hex') : '';
      const prev = typeof info.getPreviousblockhash_asU8 === 'function' ? Buffer.from(info.getPreviousblockhash_asU8()).toString('hex') : '';
      res.json({ ok: true, height, currentBlockHash: cur, previousBlockHash: prev });
    } else {
      res.json({ ok: true, base64: buf.toString('base64') });
    }
  } catch (err) {
    if (req.log) req.log.error('qscc.chaininfo.error', { error: err.message });
    res.status(500).json({ ok: false, error: err.message });
  }
});

app.get('/api/network/block/:num', async (req, res) => {
  try {
    const msp = resolveMSP(req);
    const contract = await getContractForMSPAndCC(msp, 'qscc', { discoveryEnabled: false });
    const channel = process.env.FABRIC_CHANNEL;
    const buf = await contract.evaluateTransaction('GetBlockByNumber', channel, String(req.params.num));
    const { common } = getNs();
    const block = tryDeserialize(common.Block, buf);
    if (block) {
      let number = String(req.params.num);
      const txs = [];
      try {
        if (typeof block.getHeader === 'function' && block.getHeader() && typeof block.getHeader().getNumber === 'function') {
          number = String(block.getHeader().getNumber());
        }
        const data = typeof block.getData === 'function' ? block.getData() : null;
        const envs = data && typeof data.getDataList === 'function' ? data.getDataList() : [];
        for (const env of envs) {
          const payload = tryDeserialize(common.Payload, env.getPayload_asU8 ? env.getPayload_asU8() : env.payload);
          if (!payload) continue;
          const header = typeof payload.getHeader === 'function' ? payload.getHeader() : null;
          const chdrBytes = header && typeof header.getChannelHeader_asU8 === 'function' ? header.getChannelHeader_asU8() : null;
          const chdr = tryDeserialize(common.ChannelHeader, chdrBytes);
          if (chdr) {
            const txId = typeof chdr.getTxId === 'function' ? chdr.getTxId() : chdr.tx_id;
            const timestamp = typeof chdr.getTimestamp === 'function' && chdr.getTimestamp() ? chdr.getTimestamp().toDate().toISOString() : chdr.timestamp;
            const type = typeof chdr.getType === 'function' ? chdr.getType() : chdr.type;
            txs.push({ txId, timestamp, type });
          }
        }
      } catch (_) {}
      res.json({ ok: true, block: { number, txCount: txs.length, txs } });
    } else {
      res.json({ ok: true, base64: buf.toString('base64') });
    }
  } catch (err) {
    if (req.log) req.log.error('qscc.blockByNumber.error', { error: err.message });
    res.status(500).json({ ok: false, error: err.message });
  }
});

app.get('/api/network/tx/:txId', async (req, res) => {
  try {
    const msp = resolveMSP(req);
    const contract = await getContractForMSPAndCC(msp, 'qscc', { discoveryEnabled: false });
    const channel = process.env.FABRIC_CHANNEL;
    const buf = await contract.evaluateTransaction('GetTransactionByID', channel, req.params.txId);
    const { common, peerNs } = getNs();
    const PTX = peerNs.ProcessedTransaction || (peerNs.protos && peerNs.protos.ProcessedTransaction);
    const ptx = tryDeserialize(PTX, buf);
    if (ptx) {
      let txId = req.params.txId, timestamp = undefined, validationCode = undefined;
      try {
        const te = typeof ptx.getTransactionenvelope === 'function' ? ptx.getTransactionenvelope() : ptx.transactionEnvelope;
        const payloadBytes = te && typeof te.getPayload_asU8 === 'function' ? te.getPayload_asU8() : (te ? te.payload : null);
        const payload = tryDeserialize(common.Payload, payloadBytes);
        const header = payload && typeof payload.getHeader === 'function' ? payload.getHeader() : null;
        const chdrBytes = header && typeof header.getChannelHeader_asU8 === 'function' ? header.getChannelHeader_asU8() : null;
        const chdr = tryDeserialize(common.ChannelHeader, chdrBytes);
        if (chdr) {
          txId = typeof chdr.getTxId === 'function' ? chdr.getTxId() : chdr.tx_id;
          timestamp = typeof chdr.getTimestamp === 'function' && chdr.getTimestamp() ? chdr.getTimestamp().toDate().toISOString() : chdr.timestamp;
        }
        validationCode = typeof ptx.getValidationcode === 'function' ? ptx.getValidationcode() : ptx.validationCode;
      } catch (_) {}
      res.json({ ok: true, tx: { txId, timestamp, validationCode } });
    } else {
      res.json({ ok: true, base64: buf.toString('base64') });
    }
  } catch (err) {
    if (req.log) req.log.error('qscc.txById.error', { error: err.message });
    res.status(500).json({ ok: false, error: err.message });
  }
});

app.get('/api/network/blockByTx/:txId', async (req, res) => {
  try {
    const msp = resolveMSP(req);
    const contract = await getContractForMSPAndCC(msp, 'qscc', { discoveryEnabled: false });
    const channel = process.env.FABRIC_CHANNEL;
    const buf = await contract.evaluateTransaction('GetBlockByTxID', channel, req.params.txId);
    const { common } = getNs();
    const block = tryDeserialize(common.Block, buf);
    if (block) {
      let number;
      try {
        const hdr = typeof block.getHeader === 'function' ? block.getHeader() : null;
        number = hdr && typeof hdr.getNumber === 'function' ? String(hdr.getNumber()) : undefined;
      } catch (_) {}
      res.json({ ok: true, blockNumber: number });
    } else {
      res.json({ ok: true, base64: buf.toString('base64') });
    }
  } catch (err) {
    if (req.log) req.log.error('qscc.blockByTx.error', { error: err.message });
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
    const qscc = await getContractForMSPAndCC(msp, 'qscc', { discoveryEnabled: false });
    const channel = process.env.FABRIC_CHANNEL;
    const infoBuf = await qscc.evaluateTransaction('GetChainInfo', channel);
    let height = undefined;
    {
      const { common } = getNs();
      const info = tryDeserialize(common.BlockchainInfo, infoBuf);
      if (info) height = typeof info.getHeight === 'function' ? String(info.getHeight()) : (info.height ? String(info.height) : undefined);
    }

    // Latest blocks
    const latestBlocks = [];
    const hNum = height ? parseInt(height) : 0;
    const start = hNum > 0 ? hNum - 1 : 0;
    const min = start >= (blocks - 1) ? start - (blocks - 1) : 0;
    for (let n = start; n >= min; n--) {
      try {
        const bbuf = await qscc.evaluateTransaction('GetBlockByNumber', channel, String(n));
        const { common } = getNs();
        const block = tryDeserialize(common.Block, bbuf);
        if (block) {
          let number = String(n);
          const txs = [];
          try {
            const hdr = typeof block.getHeader === 'function' ? block.getHeader() : null;
            if (hdr && typeof hdr.getNumber === 'function') number = String(hdr.getNumber());
            const data = typeof block.getData === 'function' ? block.getData() : null;
            const envs = data && typeof data.getDataList === 'function' ? data.getDataList() : [];
            for (const env of envs) {
              const payload = tryDeserialize(common.Payload, env.getPayload_asU8 ? env.getPayload_asU8() : env.payload);
              if (!payload) continue;
              const header = typeof payload.getHeader === 'function' ? payload.getHeader() : null;
              const chdrBytes = header && typeof header.getChannelHeader_asU8 === 'function' ? header.getChannelHeader_asU8() : null;
              const chdr = tryDeserialize(common.ChannelHeader, chdrBytes);
              if (chdr) {
                const txId = typeof chdr.getTxId === 'function' ? chdr.getTxId() : chdr.tx_id;
                const timestamp = typeof chdr.getTimestamp === 'function' && chdr.getTimestamp() ? chdr.getTimestamp().toDate().toISOString() : chdr.timestamp;
                const type = typeof chdr.getType === 'function' ? chdr.getType() : chdr.type;
                txs.push({ txId, timestamp, type });
              }
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
        const { common } = getNs();
        const block = tryDeserialize(common.Block, btx);
        if (block) {
          try {
            const hdr = typeof block.getHeader === 'function' ? block.getHeader() : null;
            ev.blockNumber = hdr && typeof hdr.getNumber === 'function' ? String(hdr.getNumber()) : undefined;
          } catch (_) {}
        }
      } catch (_) {}
    }

    res.json({ ok: true, network: { org, peers: peersCount, orderers: orderersCount, height }, latestBlocks, recentEvents: limited });
  } catch (err) {
    if (req.log) req.log.error('explorer.summary.error', { error: err.message });
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
  logger.info('gateway.start', { port });
});
