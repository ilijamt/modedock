import { readFileSync, readdirSync } from "node:fs";

// Only fully translated languages are published; Crowdin also skips incomplete files on export.
export const MIN_TRANSLATED = 1;

const leaves = (value, path = "") =>
  typeof value === "object" && value !== null
    ? Object.entries(value).flatMap(([key, child]) => leaves(child, path ? `${path}.${key}` : key))
    : [[path, value]];

// Crowdin leaves untranslated strings empty.
export function coverage(source, translation) {
  const done = new Map(leaves(translation).filter(([, value]) => typeof value === "string" && value.trim()));
  const keys = leaves(source).map(([key]) => key);
  return keys.filter((key) => done.has(key)).length / keys.length;
}

// Empty or missing strings fall back to the source.
export function withFallback(source, translation) {
  if (typeof source !== "object" || source === null) {
    return typeof translation === "string" && translation.trim() ? translation : source;
  }
  if (Array.isArray(source)) return source.map((value, index) => withFallback(value, translation?.[index]));
  return Object.fromEntries(Object.entries(source).map(([key, value]) => [key, withFallback(value, translation?.[key])]));
}

// For astro.config.mjs, which runs before Vite and can't import JSON with a glob.
export function readyLocales(dir, defaultLocale = "en") {
  const read = (code) => JSON.parse(readFileSync(new URL(`${code}.json`, dir), "utf8"));
  const source = read(defaultLocale);
  const others = readdirSync(dir)
    .filter((file) => file.endsWith(".json") && file !== `${defaultLocale}.json`)
    .map((file) => file.slice(0, -5))
    .filter((code) => coverage(source, read(code)) >= MIN_TRANSLATED)
    .sort();
  return [defaultLocale, ...others];
}
