/*
 Purge wallet identities (.id files) for one or more MSPs.
 Usage:
   node src/tools/purgeWallet.js --all
   node src/tools/purgeWallet.js --msp Org1MSP
   npm run purge:wallet -- --msp Org1MSP
*/

const fs = require('fs');
const path = require('path');
require('dotenv').config();

function parseArgs(argv) {
  const out = { all: false, msps: [] };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--all') out.all = true;
    else if (a === '--msp' || a === '--org') { if (argv[i+1]) out.msps.push(argv[++i]); }
  }
  return out;
}

function getOrgList() {
  const list = (process.env.FABRIC_ORGS || '').split(',').map(s => s.trim()).filter(Boolean);
  if (list.length === 0) throw new Error('FABRIC_ORGS must list at least one MSP');
  return list;
}

function getOrgEnv(mspId, key, fallback) {
  const envKey = `FABRIC_ORG_${mspId}_${key}`;
  return process.env[envKey] || fallback;
}

function purgeWalletForMSP(mspId) {
  const walletPath = getOrgEnv(mspId, 'WALLET_PATH', path.join(__dirname, '..', 'wallet', mspId));
  const absWallet = path.isAbsolute(walletPath) ? walletPath : path.resolve(__dirname, '..', walletPath);
  if (!fs.existsSync(absWallet)) {
    console.log(`[${mspId}] wallet not found: ${absWallet}`);
    return { mspId, wallet: absWallet, removed: 0, skipped: true };
  }
  const files = fs.readdirSync(absWallet);
  let removed = 0;
  for (const f of files) {
    if (f.endsWith('.id')) {
      try {
        fs.unlinkSync(path.join(absWallet, f));
        removed++;
      } catch (e) {
        console.warn(`[${mspId}] failed to remove ${f}: ${e.message}`);
      }
    }
  }
  console.log(`[${mspId}] removed ${removed} .id file(s) from ${absWallet}`);
  return { mspId, wallet: absWallet, removed };
}

function main() {
  const args = parseArgs(process.argv);
  const allMsps = getOrgList();
  let targetMsps = [];
  if (args.all) targetMsps = allMsps;
  else if (args.msps.length > 0) targetMsps = args.msps;
  else {
    console.error('Specify --all or --msp <MSP>. Example: --msp Org1MSP');
    process.exit(2);
  }

  const results = [];
  for (const msp of targetMsps) {
    results.push(purgeWalletForMSP(msp));
  }

  const total = results.reduce((n, r) => n + (r.removed || 0), 0);
  console.log(`Done. Total identities removed: ${total}`);
}

if (require.main === module) {
  try { main(); } catch (e) { console.error(e.message || String(e)); process.exit(1); }
}

