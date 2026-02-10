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

async function getContractForMSPAndCC(mspId, ccName, opts = undefined) {
  const discoveryEnabledEnv = (process.env.FABRIC_DISCOVERY_ENABLED || 'true') === 'true';
  const discoveryEnabled = (opts && Object.prototype.hasOwnProperty.call(opts, 'discoveryEnabled')) ? !!opts.discoveryEnabled : discoveryEnabledEnv;
  const discoveryKey = discoveryEnabled ? 'disc' : 'nodisc';
  const key = `${mspId}:${ccName}:${discoveryKey}`;
  if (cache.has(key)) {
    logger.debug('gateway.cache.hit', { mspId, ccName });
    return cache.get(key).contract;
  }

  const channelName = process.env.FABRIC_CHANNEL;
  const chaincodeName = process.env.FABRIC_CHAINCODE;
  const discoveryAsLocalhost = (process.env.FABRIC_DISCOVERY_ASLOCALHOST || 'true') === 'true';

  if (!channelName || !ccName) {
    throw new Error('Missing required env: FABRIC_CHANNEL, FABRIC_CHAINCODE');
  }

  const ccpPathRaw = getOrgEnv(mspId, 'CCP_PATH');
  const ccpPath = ccpPathRaw && (path.isAbsolute(ccpPathRaw) ? ccpPathRaw : path.resolve(__dirname, '..', ccpPathRaw));
  const walletPath = getOrgEnv(mspId, 'WALLET_PATH', path.join(__dirname, '..', 'wallet', mspId));
  const identityLabel = getOrgEnv(mspId, 'IDENTITY', 'appUser');
  if (!ccpPath) throw new Error(`Missing CCP for ${mspId}: FABRIC_ORG_${mspId}_CCP_PATH`);

  logger.info('gateway.connect.begin', { mspId, ccName, channelName, identityLabel, ccpPath, discoveryEnabled, discoveryAsLocalhost });
  const ccp = JSON.parse(fs.readFileSync(ccpPath, 'utf8'));
  const wallet = await Wallets.newFileSystemWallet(walletPath);
  const existing = await wallet.get(identityLabel);
  const certPathRaw = getOrgEnv(mspId, 'CERT_PATH');
  const keyPathRaw = getOrgEnv(mspId, 'KEY_PATH');
  const certPath = certPathRaw && (path.isAbsolute(certPathRaw) ? certPathRaw : path.resolve(__dirname, '..', certPathRaw));
  const keyPath = keyPathRaw && (path.isAbsolute(keyPathRaw) ? keyPathRaw : path.resolve(__dirname, '..', keyPathRaw));

  if (!existing) {
    if (!certPath || !keyPath) {
      throw new Error(`Identity ${identityLabel} for ${mspId} not found in wallet and CERT/KEY env not provided`);
    }
    const cert = fs.readFileSync(certPath, 'utf8');
    const key = fs.readFileSync(keyPath, 'utf8');
    const identity = { credentials: { certificate: cert, privateKey: key }, mspId: mspId, type: 'X.509' };
    await wallet.put(identityLabel, identity);
    logger.info('gateway.identity.imported', { mspId, identityLabel });
  } else {
    // Validate MSP ID and optionally refresh credentials if files differ
    if (existing.mspId && existing.mspId !== mspId) {
      throw new Error(`Wallet identity '${identityLabel}' has mspId='${existing.mspId}' but expected '${mspId}'. Remove ${path.join(walletPath, identityLabel + '.id')} to re-import.`);
    }
    if (certPath && keyPath) {
      try {
        const certFile = fs.readFileSync(certPath, 'utf8');
        const keyFile = fs.readFileSync(keyPath, 'utf8');
        const curCert = existing.credentials && existing.credentials.certificate;
        const curKey = existing.credentials && existing.credentials.privateKey;
        if (curCert !== certFile || curKey !== keyFile) {
          const identity = { credentials: { certificate: certFile, privateKey: keyFile }, mspId: mspId, type: 'X.509' };
          await wallet.put(identityLabel, identity);
          logger.warn('gateway.identity.updated', { mspId, identityLabel, reason: 'cert/key changed on disk' });
        }
      } catch (e) {
        logger.warn('gateway.identity.refresh.error', { mspId, identityLabel, error: e && e.message });
      }
    }
  }

  const gateway = new Gateway();
  try {
    await gateway.connect(ccp, {
      wallet,
      identity: identityLabel,
      discovery: { enabled: discoveryEnabled, asLocalhost: discoveryAsLocalhost },
    });
  } catch (e) {
    const msg = (e && e.message) || '';
    if (discoveryEnabled && /DiscoveryService|access denied|discovery error/i.test(msg)) {
      logger.warn('gateway.connect.retryNoDiscovery', { mspId, ccName, reason: msg });
      await gateway.connect(ccp, {
        wallet,
        identity: identityLabel,
        discovery: { enabled: false, asLocalhost: discoveryAsLocalhost },
      });
    } else {
      throw e;
    }
  }

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
