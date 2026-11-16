// @ts-check
import { defineConfig } from "astro/config";
import { readyLocales } from "./src/i18n/locales.mjs";

export default defineConfig({
  site: "https://modedock.app",
  i18n: {
    defaultLocale: "en",
    locales: readyLocales(new URL("./src/i18n/", import.meta.url)),
    routing: { prefixDefaultLocale: false },
  },
});
