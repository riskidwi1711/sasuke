const fs = require('fs');
const path = require('path');
const { Gateway, Wallets } = require('fabric-network');
const logger = require('./logger');

// cache per-org and chaincode
const cache = new Map(); // key: `${mspId}:${ccName}`, value: { gateway, contract }

function getOrgList() {
  const list = (process.env.FABRIC_ORGS || '').split(',').map(s => s.trim()).filter(Boolean);
  if (list.length === 0) throw new Error('FABRIC_ORGS must list at least one MSP');
  return list;
}

function getOrgEnv(mspId, key, fallback) {
  const envKey = `FABRIC_ORG_${mspId}_${key}`;
  return process.env[envKey] || fallback;
}

async function getContractForMSP(mspId) {
  const appCC = process.env.FABRIC_CHAINCODE;
  return getContractForMSPAndCC(mspId, appCC);
}

async function getContractForMSPAndCC(mspId, ccName) {
  const key = `${mspId}:${ccName}`;
  if (cache.has(key)) {
    logger.debug('gateway.cache.hit', { mspId, ccName });
    return cache.get(key).contract;
  }

  const channelName = process.env.FABRIC_CHANNEL;
  const chaincodeName = process.env.FABRIC_CHAINCODE;
  const discoveryEnabled = (process.env.FABRIC_DISCOVERY_ENABLED || 'true') === 'true';
  const discoveryAsLocalhost = (process.env.FABRIC_DISCOVERY_ASLOCALHOST || 'true') === 'true';

  if (!channelName || !ccName) {
    throw new Error('Missing required env: FABRIC_CHANNEL, FABRIC_CHAINCODE');
  }

  const ccpPath = getOrgEnv(mspId, 'CCP_PATH');
  const walletPath = getOrgEnv(mspId, 'WALLET_PATH', path.join(__dirname, '..', 'wallet', mspId));
  const identityLabel = getOrgEnv(mspId, 'IDENTITY', 'appUser');
  if (!ccpPath) throw new Error(`Missing CCP for ${mspId}: FABRIC_ORG_${mspId}_CCP_PATH`);

  logger.info('gateway.connect.begin', { mspId, ccName, channelName, identityLabel, ccpPath, discoveryEnabled, discoveryAsLocalhost });
  const ccp = JSON.parse(fs.readFileSync(ccpPath, 'utf8'));
  const wallet = await Wallets.newFileSystemWallet(walletPath);

  if (!await wallet.get(identityLabel)) {
    const certPath = getOrgEnv(mspId, 'CERT_PATH');
    const keyPath = getOrgEnv(mspId, 'KEY_PATH');
    if (!certPath || !keyPath) {
      throw new Error(`Identity ${identityLabel} for ${mspId} not found in wallet and CERT/KEY env not provided`);
    }
    const cert = fs.readFileSync(certPath, 'utf8');
    const key = fs.readFileSync(keyPath, 'utf8');
    const identity = {
      credentials: { certificate: cert, privateKey: key },
      mspId: mspId,
      type: 'X.509',
    };
    await wallet.put(identityLabel, identity);
    logger.info('gateway.identity.imported', { mspId, identityLabel });
  }

  const gateway = new Gateway();
  await gateway.connect(ccp, {
    wallet,
    identity: identityLabel,
    discovery: { enabled: discoveryEnabled, asLocalhost: discoveryAsLocalhost },
  });

  const network = await gateway.getNetwork(channelName);
  const contract = network.getContract(ccName);
  logger.info('gateway.contract.ready', { mspId, ccName, channelName });

  cache.set(key, { gateway, contract });
  return contract;
}

async function disconnectAll() {
  for (const [key, { gateway }] of cache.entries()) {
    try { await gateway.disconnect(); } catch (e) { logger.warn('gateway.disconnect.error', { error: e && e.message }); }
    cache.delete(key);
  }
  logger.info('gateway.disconnectAll.done');
}

module.exports = { getContractForMSP, getContractForMSPAndCC, disconnectAll, getOrgList };
