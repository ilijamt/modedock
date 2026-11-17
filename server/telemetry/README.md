# ModeDock telemetry

A Cloudflare Worker that receives the app's anonymous usage reports at
`https://telemetry.modedock.app/v1/reports` and stores them in D1. Terraform creates the
Worker, the database (in the EU), the hostname and the rate limit. This folder has the code
and the schema.

## Deploy

```sh
wrangler d1 migrations apply modedock-telemetry --remote
wrangler deploy
```

`database_id` in `wrangler.toml` comes from `terraform output modedock_telemetry_d1_id`.

## Run it locally

```sh
wrangler d1 migrations apply modedock-telemetry --local
wrangler dev --local
```

Point a debug build at it with `-telemetry.endpoint http://127.0.0.1:8787/v1/reports`.

## What it stores

One row per report: the report and install IDs, the day it arrived, the app and macOS
versions, language, architecture, counts, setup and the country Cloudflare looked up. It
never reads IP addresses or headers, and logging is off.

A report sent again with the same ID replaces the earlier copy, but only for the install that
sent it. Anything malformed gets a 4xx.

## Public stats

`GET /v1/stats` serves totals for the last 30 days to the website. A cron at 17 minutes past each hour
recomputes them. Groups under 5 installs are left out, so no single install shows. For macOS
versions and countries, each install counts once, with its latest value. The total minus the
groups shown is then a number too, so more small groups are left out until that rest is none or
at least 5. Context values the app can't send
are stored as `?` and never shown.

To run the cron locally:

```sh
wrangler dev --local --test-scheduled
curl "http://127.0.0.1:8787/__scheduled?cron=17+*+*+*+*"
```
