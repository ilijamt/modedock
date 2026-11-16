import { defineCollection, z } from "astro:content";
import { glob } from "astro/loaders";

// One file per language, named by its code (en.md, ja.md, …).
const privacy = defineCollection({
  loader: glob({ pattern: "*.md", base: "./src/content/privacy" }),
  schema: z.object({ title: z.string(), description: z.string() }),
});

export const collections = { privacy };
