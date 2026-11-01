// Receives ModeDock's anonymous usage reports and stores one row per report in D1, with the
// country Cloudflare looked up for the request. The IP address and headers are never read.

const MAX_BODY = 64 * 1024;
const UUID = /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$/;
const KEY = /^[A-Za-z0-9._-]{1,64}$/;
// Cloudflare uses XX for unknown and T1 for Tor; neither is a country.
const COUNTRY = /^(?!XX$|T1$)[A-Z]{2}$/;

export default {
  async fetch(request, env) {
    const { pathname } = new URL(request.url);
    if (pathname !== "/v1/reports") return new Response(null, { status: 404 });
    if (request.method !== "POST") return new Response(null, { status: 405, headers: { Allow: "POST" } });

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
  },
};

// Returns the report with UUIDs lowercased, or throws if anything is off.
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

  // Setup is a flat object of numbers, booleans, short strings and lists of short strings.
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

// Only the country Cloudflare looked up for the request; the IP itself is never read.
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
