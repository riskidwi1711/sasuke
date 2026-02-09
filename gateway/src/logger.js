const util = require('util');

const LEVELS = { error: 0, warn: 1, info: 2, debug: 3, trace: 4 };

const envLevel = (process.env.LOG_LEVEL || 'info').toLowerCase();
const LOG_LEVEL = LEVELS[envLevel] !== undefined ? LEVELS[envLevel] : LEVELS.info;
const LOG_FORMAT = (process.env.LOG_FORMAT || 'text').toLowerCase(); // 'text' | 'json'

function nowISO() {
  return new Date().toISOString();
}

function serialize(value) {
  if (value instanceof Error) {
    return { message: value.message, stack: value.stack };
  }
  return value;
}

function baseLogger(context = {}) {
  function shouldLog(level) { return LEVELS[level] <= LOG_LEVEL; }

  function emit(level, msg, meta) {
    if (!shouldLog(level)) return;
    const line = { level, time: nowISO(), msg: String(msg), ...context, ...meta };
    if (LOG_FORMAT === 'json') {
      // eslint-disable-next-line no-console
      console.log(JSON.stringify(line));
    } else {
      const ctxPairs = Object.entries({ ...context, ...meta })
        .filter(([, v]) => v !== undefined)
        .map(([k, v]) => `${k}=${typeof v === 'string' ? v : util.inspect(serialize(v), { depth: 3 })}`)
        .join(' ');
      // eslint-disable-next-line no-console
      console.log(`[${line.time}] ${level.toUpperCase()} ${msg}${ctxPairs ? ' | ' + ctxPairs : ''}`);
    }
  }

  return {
    child(extra = {}) { return baseLogger({ ...context, ...extra }); },
    error(msg, meta = {}) { emit('error', msg, meta); },
    warn(msg, meta = {}) { emit('warn', msg, meta); },
    info(msg, meta = {}) { emit('info', msg, meta); },
    debug(msg, meta = {}) { emit('debug', msg, meta); },
    trace(msg, meta = {}) { emit('trace', msg, meta); },
  };
}

module.exports = baseLogger();

