# modedock.app

The ModeDock website, a static Astro site. Cloudflare Pages builds it when `web/` changes on
`main`.

```sh
npm install
npm run dev       # http://localhost:4321
npm run build     # output in dist/
```

The usage stats come from `https://telemetry.modedock.app/v1/stats` and stay hidden until at
least 5 installs have reported.
