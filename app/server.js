import { readFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { Client } from '@elastic/elasticsearch';
import { createSentinel } from 'redis';

const required = [
  'ELASTICSEARCH_URL',
  'ELASTICSEARCH_USERNAME',
  'ELASTICSEARCH_PASSWORD',
  'ELASTICSEARCH_CA_FILE',
  'REDIS_SENTINEL_HOST',
  'REDIS_SENTINEL_PORT',
  'REDIS_MASTER_NAME',
  'REDIS_PASSWORD',
  'REDIS_CA_FILE',
];

for (const name of required) {
  if (!process.env[name]) {
    console.error(`[config] missing environment variable: ${name}`);
    process.exit(1);
  }
}

if (!process.env.ELASTICSEARCH_URL.startsWith('https://')) {
  console.error('[elasticsearch] ELASTICSEARCH_URL must use https://');
  process.exit(1);
}

const sentinelPort = Number(process.env.REDIS_SENTINEL_PORT);
if (!Number.isInteger(sentinelPort) || sentinelPort < 1 || sentinelPort > 65535) {
  console.error('[redis] REDIS_SENTINEL_PORT must be a valid TCP port');
  process.exit(1);
}

function loadCa(service, path) {
  try {
    return readFileSync(path);
  } catch (error) {
    console.error(`[${service}] cannot read CA certificate ${path}: ${error.message}`);
    process.exit(1);
  }
}

const elasticsearchCa = loadCa('elasticsearch', process.env.ELASTICSEARCH_CA_FILE);
const redisCa = loadCa('redis', process.env.REDIS_CA_FILE);
const state = { elasticsearch: false, redis: false };

const elasticsearch = new Client({
  node: process.env.ELASTICSEARCH_URL,
  auth: {
    username: process.env.ELASTICSEARCH_USERNAME,
    password: process.env.ELASTICSEARCH_PASSWORD,
  },
  tls: { ca: elasticsearchCa, rejectUnauthorized: true },
  requestTimeout: 5000,
});

const redis = createSentinel({
  name: process.env.REDIS_MASTER_NAME,
  sentinelRootNodes: [{
    host: process.env.REDIS_SENTINEL_HOST,
    port: sentinelPort,
  }],
  passthroughClientErrorEvents: true,
  sentinelClientOptions: {
    password: process.env.REDIS_PASSWORD,
    socket: { tls: true, ca: [redisCa], rejectUnauthorized: true },
  },
  nodeClientOptions: {
    password: process.env.REDIS_PASSWORD,
    socket: { tls: true, ca: [redisCa], rejectUnauthorized: true },
  },
});

function errorMessage(error) {
  return error instanceof Error ? error.message : String(error);
}

async function checkElasticsearch() {
  try {
    await elasticsearch.ping();
    if (!state.elasticsearch) {
      console.info(`[elasticsearch] connected over TLS: ${process.env.ELASTICSEARCH_URL}`);
    }
    state.elasticsearch = true;
  } catch (error) {
    state.elasticsearch = false;
    console.error(`[elasticsearch] TLS connection failed: ${errorMessage(error)}`);
  } finally {
    setTimeout(checkElasticsearch, 15000);
  }
}

async function checkRedis() {
  if (!redis.isReady) {
    state.redis = false;
    return;
  }
  try {
    await redis.ping();
    if (!state.redis) {
      console.info(`[redis] connected over TLS via Sentinel ${process.env.REDIS_SENTINEL_HOST}:${sentinelPort} (master: ${process.env.REDIS_MASTER_NAME})`);
    }
    state.redis = true;
  } catch (error) {
    state.redis = false;
    console.error(`[redis] TLS connection failed: ${errorMessage(error)}`);
  }
}

redis.on('ready', () => { void checkRedis(); });
redis.on('reconnecting', () => {
  state.redis = false;
  console.warn('[redis] reconnecting to Sentinel/Redis over TLS');
});
redis.on('end', () => { state.redis = false; });
redis.on('error', error => {
  state.redis = false;
  console.error(`[redis] TLS connection failed: ${errorMessage(error)}`);
});

async function connectRedis() {
  try {
    await redis.connect();
  } catch (error) {
    state.redis = false;
    console.error(`[redis] TLS connection failed: ${errorMessage(error)}`);
    setTimeout(connectRedis, 10000);
  }
}

const server = createServer((request, response) => {
  if (request.url === '/healthz') {
    response.writeHead(200).end('ok');
    return;
  }
  if (request.url === '/readyz') {
    const ready = state.elasticsearch && state.redis;
    response.writeHead(ready ? 200 : 503, { 'content-type': 'application/json' });
    response.end(JSON.stringify(state));
    return;
  }
  response.writeHead(404).end('not found');
});

const port = Number(process.env.PORT || 3000);
server.listen(port, '0.0.0.0', () => {
  console.info(`[app] listening on port ${port}`);
});

void checkElasticsearch();
void connectRedis();
setInterval(() => { void checkRedis(); }, 15000);

async function shutdown() {
  server.close();
  await Promise.allSettled([
    redis.isOpen ? redis.close() : Promise.resolve(),
    elasticsearch.close(),
  ]);
  process.exit(0);
}

process.on('SIGTERM', () => { void shutdown(); });
process.on('SIGINT', () => { void shutdown(); });
