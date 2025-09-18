export default {
  async fetch(req: Request, env: any): Promise<Response> {
    const url = new URL(req.url);
    const reqOrigin = req.headers.get("Origin") || "";
    const allowedOrigin = (env.ALLOWED_ORIGIN === "*" ? (reqOrigin || "*") : env.ALLOWED_ORIGIN);
    const cors: Record<string, string> = {
      "Access-Control-Allow-Origin": allowedOrigin,
      "Access-Control-Allow-Credentials": "true",
      "Vary": "origin",
      "Access-Control-Allow-Headers": "content-type,authorization,idempotency-key",
      "Access-Control-Expose-Headers": "content-type,authorization,idempotency-key",
      "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
      "Access-Control-Max-Age": "86400",
      "Content-Type": "application/json; charset=utf-8"
    };
    if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
    const json = (b:any,s=200)=>new Response(JSON.stringify(b),{status:s,headers:cors});

    async function ensureSchema() {
      await env.DB.prepare(`
        CREATE TABLE IF NOT EXISTS Inventory (
          id TEXT PRIMARY KEY,
          sku TEXT UNIQUE NOT NULL,
          title TEXT NOT NULL,
          category TEXT NOT NULL,
          status TEXT NOT NULL DEFAULT 'active',
          cost_cents INTEGER NOT NULL DEFAULT 0,
          quantity INTEGER NOT NULL DEFAULT 0,
          created_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
        );
      `).run();
      await env.DB.prepare(\`CREATE INDEX IF NOT EXISTS idx_inventory_sku ON Inventory(sku);\`).run();
    }
    async function requireAuth() {
      const h = req.headers.get("Authorization") || "";
      const token = h.startsWith("Bearer ") ? h.slice(7) : "";
      const expected = env.OWNER_TOKEN || "";
      if (!token || (expected && token !== expected)) return json({ error: { code: "unauthorized", message: "Missing or invalid token" } }, 401);
      if (req.method !== "GET" && !req.headers.get("Idempotency-Key")) return json({ error: { code: "bad_request", message: "Idempotency-Key required" } }, 400);
      return null;
    }

    if (url.pathname === "/api/health" && req.method === "GET") return json({ ok: true });

    if (url.pathname === "/api/inventory" && req.method === "GET") {
      await ensureSchema();
      const rs = await env.DB.prepare("SELECT id,sku,title,category,status,cost_cents,quantity,created_at FROM Inventory ORDER BY created_at DESC LIMIT 100").all();
      return json({ items: rs.results || [] });
    }

    if (url.pathname === "/api/inventory" && req.method === "POST") {
      const unauthorized = await requireAuth(); if (unauthorized) return unauthorized;
      await ensureSchema();
      let body:any={}; try { body = await req.json(); } catch { return json({error:{code:"bad_json",message:"Invalid JSON body"}},400); }
      const { sku, title, category, status, cost_cents, cost_usd, quantity = 1 } = body || {};
      if (!sku || !title || !category) return json({error:{code:"bad_request",message:"sku, title, category are required"}},400);
      const normalizedStatus = (()=>{ const v=String(status||"").toLowerCase(); return ["staged","draft","active","sold"].includes(v)?v:"active"; })();
      const cents = Number.isFinite(cost_cents) ? Number(cost_cents) : (Number.isFinite(cost_usd) ? Math.round(Number(cost_usd)*100) : 0);
      const id = crypto.randomUUID();
      try {
        await env.DB.prepare("INSERT INTO Inventory (id,sku,title,category,status,cost_cents,quantity) VALUES (?1,?2,?3,?4,?5,?6,?7)")
          .bind(id, sku, title, category, normalizedStatus, cents, Number(quantity)||1).run();
      } catch (e:any) { return json({error:{code:"db_error",message:e?.message||String(e)}},500); }
      return json({ ok:true, id, sku, title, category, status: normalizedStatus, cost_cents: cents, quantity: Number(quantity)||1 }, 201);
    }

    return json({ error:{ code:"not_found", message:"Route not found" }, routes:["GET /api/health","GET /api/inventory","POST /api/inventory"] }, 404);
  }
};
