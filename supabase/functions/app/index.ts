// Serves the City Jeans drops app.
//
// The pages themselves live in the public `web` storage bucket, so shipping an
// update means re-uploading index.html / admin.html / config.js — this function
// does not need redeploying. It exists because Supabase Storage returns HTML as
// text/plain; here we hand it back with the right content type.
//
// Public by design: this is the customer-facing storefront, so verify_jwt is off.

const PROJECT = "https://nrncccfqgwxcugqdouvs.supabase.co";
const BUCKET = `${PROJECT}/storage/v1/object/public/web`;
const BASE = "/functions/v1/app";

const ROUTES: Record<string, [string, string]> = {
  "": ["index.html", "text/html; charset=utf-8"],
  "/": ["index.html", "text/html; charset=utf-8"],
  "/index.html": ["index.html", "text/html; charset=utf-8"],
  "/admin": ["admin.html", "text/html; charset=utf-8"],
  "/admin/": ["admin.html", "text/html; charset=utf-8"],
  "/admin.html": ["admin.html", "text/html; charset=utf-8"],
  "/config.js": ["config.js", "application/javascript; charset=utf-8"],
};

type Entry = { body: string; at: number };
const cache = new Map<string, Entry>();
const TTL = 30_000;

async function load(file: string): Promise<string | null> {
  const hit = cache.get(file);
  if (hit && Date.now() - hit.at < TTL) return hit.body;
  const r = await fetch(`${BUCKET}/${file}`, { cache: "no-store" });
  if (!r.ok) return null;
  let body = await r.text();
  // `config.js` is referenced relatively, which breaks at /functions/v1/app
  // (no trailing slash). Pin it to an absolute path instead.
  body = body.replace('src="config.js"', `src="${BASE}/config.js"`);
  cache.set(file, { body, at: Date.now() });
  return body;
}

Deno.serve(async (req: Request) => {
  const url = new URL(req.url);
  // Supabase routes /functions/v1/<name>/<rest> here; strip both prefixes.
  const path = url.pathname
    .replace(/^\/functions\/v1/, "")
    .replace(/^\/[^/]+/, "");

  const route = ROUTES[path];
  if (!route) return new Response("Not found", { status: 404 });

  const [file, type] = route;
  const body = await load(file);
  if (body === null) {
    return new Response("App files not uploaded yet", { status: 503 });
  }

  return new Response(body, {
    headers: {
      "Content-Type": type,
      "Cache-Control": "public, max-age=30",
      "X-Content-Type-Options": "nosniff",
      "Referrer-Policy": "strict-origin-when-cross-origin",
    },
  });
});
