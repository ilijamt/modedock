# ModeDock telemetry

A Cloudflare Worker that takes the app's anonymous usage reports at
`https://telemetry.modedock.app/v1/reports` and stores one row per report in D1.

The Worker, the D1 database (EU jurisdiction), the hostname and a rate limit are created by
Terraform in `homelab/terraform/matoski/modedock_app.tf`. This folder holds the script and
the schema, deployed with wrangler.

## Deploy

```
# once, after terraform apply: put the id into wrangler.toml as database_id
terraform output modedock_telemetry_d1_id

wrangler d1 migrations apply modedock-telemetry --remote
wrangler deploy
```

## Try it locally

```
wrangler d1 migrations apply modedock-telemetry --local
wrangler dev --local
```

Point a debug build at it with `-telemetry.endpoint http://127.0.0.1:8787/v1/reports`.

## What it stores

The report ID, install ID, the UTC day it arrived, the app and macOS versions, language,
architecture, the counts and the setup, plus the country Cloudflare looked up for the request
(`request.cf.country`). It never reads or stores IP addresses or headers, and Workers logs
are off. Show country breakdowns only for groups of at least 5 installs, so a rare country
can't single anyone out.

A resend with the same report ID replaces the row, but only for the install that sent it.
Anything that isn't a well-formed report gets a 4xx and isn't stored.

## Public stats

A daily cron (03:17 UTC) aggregates the last 30 days into one row of the `stats` table, and
`GET /v1/stats` serves it (cached for an hour, open CORS) for the home page. Every number
counts distinct installs and any group under 5 installs is left out, so no install ID or
single report is ever published. Until the first run it answers 404.

To run it once by hand after a deploy, trigger the cron from the dashboard, or locally:

```
wrangler dev --local --test-scheduled
curl "http://127.0.0.1:8787/__scheduled?cron=17+3+*+*+*"
```
