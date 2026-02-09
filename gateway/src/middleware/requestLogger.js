const crypto = require('crypto');
const logger = require('../logger');

function genId() {
  if (crypto.randomUUID) return crypto.randomUUID();
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
}

const LOG_BODY = (process.env.LOG_REQUEST_BODY || 'false').toLowerCase() === 'true';
const BODY_MAX = parseInt(process.env.LOG_REQUEST_BODY_MAX || '2048', 10);

module.exports = function requestLogger(req, res, next) {
  const incomingId = req.get('x-request-id');
  const reqId = incomingId || genId();
  res.setHeader('x-request-id', reqId);

  const start = process.hrtime.bigint ? process.hrtime.bigint() : process.hrtime();
  const l = logger.child({ reqId });
  req.log = l;

  const meta = { method: req.method, url: req.originalUrl || req.url, ip: req.ip };
  if (LOG_BODY && req.body) {
    try {
      const raw = typeof req.body === 'string' ? req.body : JSON.stringify(req.body);
      meta.body = raw.length > BODY_MAX ? raw.slice(0, BODY_MAX) + `...(${raw.length} bytes)` : raw;
    } catch (_) {}
  }
  l.info('req.start', meta);

  res.on('finish', () => {
    const end = process.hrtime.bigint ? process.hrtime.bigint() : process.hrtime(start);
    const ms = typeof end === 'bigint' ? Number(end / 1000000n) : Math.round((end[0] * 1e9 + end[1]) / 1e6);
    l.info('req.end', { status: res.statusCode, durationMs: ms });
  });
  res.on('close', () => {
    // client aborted
    l.warn('req.aborted');
  });
  next();
};

