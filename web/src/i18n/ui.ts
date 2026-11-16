import { getRelativeLocaleUrl } from "astro:i18n";
import en from "./en.json";
import { MIN_TRANSLATED, coverage, withFallback } from "./locales.mjs";

export type UI = typeof en;
export type Lang = string;
export const defaultLang: Lang = "en";

const files = import.meta.glob<UI>("./*.json", { eager: true, import: "default" });
const translations = Object.fromEntries(
  Object.entries(files)
    .map(([path, strings]) => [path.slice(2, -5), strings] as const)
    .filter(([code, strings]) => code === defaultLang || coverage(en, strings) >= MIN_TRANSLATED),
);

export const langs: Lang[] = [defaultLang, ...Object.keys(translations).filter((code) => code !== defaultLang).sort()];
export const ui: Record<Lang, UI> = Object.fromEntries(langs.map((code) => [code, withFallback(en, translations[code]) as UI]));

// Each language in its own name.
export const languages: Record<Lang, string> = Object.fromEntries(
  langs.map((code) => {
    const name = new Intl.DisplayNames([code], { type: "language" }).of(code) ?? code;
    return [code, name.charAt(0).toLocaleUpperCase(code) + name.slice(1)];
  }),
);

// Astro lowercases locale URLs (zh-Hans becomes /zh-hans/), so the pages must live there too.
export function langPaths() {
  return langs.map((lang) => ({
    params: { lang: lang === defaultLang ? undefined : lang.toLowerCase() },
    props: { lang },
  }));
}

export function url(lang: Lang, path = "") {
  return getRelativeLocaleUrl(lang, path);
}
