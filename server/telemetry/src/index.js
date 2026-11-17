// Never reads the request's IP address or headers.

const MAX_BODY = 64 * 1024;
const UUID = /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$/;
const KEY = /^[A-Za-z0-9._-]{1,64}$/;
// Cloudflare uses XX for unknown and T1 for Tor; neither is a country.
const COUNTRY = /^(?!XX$|T1$)[A-Z]{2}$/;
const STATS_DAYS = 30;
// No number in the public stats describes fewer installs than this, so nobody can be singled out.
const MIN_INSTALLS = 5;

export default {
  async fetch(request, env) {
    const { pathname } = new URL(request.url);
    if (pathname === "/v1/stats") {
      if (request.method !== "GET") return new Response(null, { status: 405, headers: { Allow: "GET" } });
      return serveStats(env);
    }
    if (pathname !== "/v1/reports") return new Response(null, { status: 404 });
    if (request.method !== "POST") return new Response(null, { status: 405, headers: { Allow: "POST" } });
    return receive(request, env);
  },

  async scheduled(_event, env, ctx) {
    ctx.waitUntil(updateStats(env));
  },
};

async function receive(request, env) {
  const body = await request.text();
  if (body.length === 0 || body.length > MAX_BODY) return new Response(null, { status: 413 });

  let report;
  try {
    report = parse(JSON.parse(body));
  } catch {
    return new Response(null, { status: 400 });
  }

  // A resend from the same install replaces its earlier copy; another install can't.
  await env.DB.prepare(
    `INSERT INTO reports (report, install, day, schema, app_version, os_version, language, architecture, country, counts, setup)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
     ON CONFLICT (report) DO UPDATE SET
       day = excluded.day, schema = excluded.schema, app_version = excluded.app_version,
       os_version = excluded.os_version, language = excluded.language,
       architecture = excluded.architecture, country = excluded.country, counts = excluded.counts,
       setup = excluded.setup
     WHERE reports.install = excluded.install`,
  )
    .bind(
      report.report,
      report.install,
      new Date().toISOString().slice(0, 10),
      report.schema,
      report.context.appVersion,
      report.context.osVersion,
      report.context.language,
      report.context.architecture,
      country(request),
      JSON.stringify(report.counts),
      report.setup === undefined ? null : JSON.stringify(report.setup),
    )
    .run();

  return new Response(null, { status: 204 });
}

const PUBLIC = { "Access-Control-Allow-Origin": "*", "Cache-Control": "public, max-age=3600" };

async function serveStats(env) {
  const read = () => env.DB.prepare("SELECT body FROM stats WHERE id = 1").first();
  let row = await read();
  // Right after a deploy the cron hasn't run yet.
  if (!row) {
    await updateStats(env);
    row = await read();
  }
  return new Response(row.body, { headers: { ...PUBLIC, "Content-Type": "application/json" } });
}

async function updateStats(env) {
  const since = new Date(Date.now() - STATS_DAYS * 86_400_000).toISOString().slice(0, 10);
  const total = await env.DB.prepare("SELECT COUNT(DISTINCT install) AS n FROM reports WHERE day >= ?1")
    .bind(since)
    .first("n");

  const stats = { updated: new Date().toISOString(), days: STATS_DAYS, minimum: MIN_INSTALLS, installs: null };
  if (total >= MIN_INSTALLS) {
    const group = async (column) => {
      const { results } = await env.DB.prepare(
        `SELECT ${column} AS name, COUNT(DISTINCT install) AS installs FROM reports
         WHERE day >= ?1 AND ${column} IS NOT NULL GROUP BY ${column}
         HAVING installs >= ?2 ORDER BY installs DESC LIMIT 20`,
      )
        .bind(since, MIN_INSTALLS)
        .all();
      return results;
    };
    const { results: features } = await env.DB.prepare(
      `SELECT c.key AS name, COUNT(DISTINCT r.install) AS installs
       FROM reports r, json_each(r.counts) c
       WHERE r.day >= ?1 AND c.value > 0 AND c.key NOT LIKE 'app.%' AND c.key NOT LIKE 'error.%' AND c.key NOT LIKE 'source.%'
       GROUP BY c.key HAVING installs >= ?2 ORDER BY installs DESC, SUM(c.value) DESC LIMIT 25`,
    )
      .bind(since, MIN_INSTALLS)
      .all();
    Object.assign(stats, {
      installs: total,
      macos: await group("os_version"),
      countries: await group("country"),
      features,
    });
  }

  await env.DB.prepare(
    `INSERT INTO stats (id, body, updated) VALUES (1, ?1, ?2)
     ON CONFLICT (id) DO UPDATE SET body = excluded.body, updated = excluded.updated`,
  )
    .bind(JSON.stringify(stats), stats.updated)
    .run();
}

function parse(value) {
  check(isObject(value) && value.schema === 1);
  check(typeof value.install === "string" && UUID.test(value.install));
  check(typeof value.report === "string" && UUID.test(value.report));

  const context = value.context;
  check(isObject(context));
  for (const field of ["appVersion", "osVersion", "language", "architecture"]) {
    check(typeof context[field] === "string" && context[field].length <= 32);
  }

  const counts = value.counts;
  check(isObject(counts) && Object.keys(counts).length <= 500);
  for (const [key, count] of Object.entries(counts)) {
    check(KEY.test(key) && Number.isInteger(count) && count >= 0 && count <= 1_000_000);
  }

  const setup = value.setup;
  if (setup !== undefined) {
    check(isObject(setup) && Object.keys(setup).length <= 100);
    for (const [key, item] of Object.entries(setup)) {
      check(KEY.test(key) && isSetupValue(item));
    }
  }

  return {
    schema: 1,
    install: value.install.toLowerCase(),
    report: value.report.toLowerCase(),
    context,
    counts,
    setup,
  };
}

function country(request) {
  const code = request.cf?.country;
  return typeof code === "string" && COUNTRY.test(code) ? code : null;
}

function isSetupValue(item) {
  if (typeof item === "boolean" || (typeof item === "number" && Number.isFinite(item))) return true;
  if (typeof item === "string") return item.length <= 64;
  if (Array.isArray(item)) return item.length <= 50 && item.every((entry) => typeof entry === "string" && entry.length <= 64);
  if (isObject(item)) {
    return Object.keys(item).length <= 20 && Object.entries(item).every(([key, entry]) => KEY.test(key) && isSetupValue(entry));
  }
  return false;
}

function isObject(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function check(condition) {
  if (!condition) throw new Error("invalid report");
}
