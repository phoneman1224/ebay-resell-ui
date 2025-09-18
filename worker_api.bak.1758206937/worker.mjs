/**
 * Minimal Cloudflare Worker API for eBay Resell App
 * Routes:
 *   GET  /api/health            -> { ok: true }
 *   GET  /api/inventory         -> list items
 *   POST /api/inventory         -> create item
 *   PATCH /api/inventory/:id    -> update status/quantity (owner token required)
 *   GET  /api/debug/auth        -> { ok: true } if owner token matches (optional)
 *
 * Bindings:
 *   env.DB   : D1Database (binding name "DB")
 *   env.ALLOWED_ORIGIN : CORS allowlist origin (string)
 *   env.OWNER_TOKEN    : secret owner token
 */
export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const origin = request.headers.get('Origin') || '*';

    // CORS
    const allowed = env.ALLOWED_ORIGIN || '*';
    const corsHeaders = {
      'Access-Control-Allow-Origin': allowed === '*' ? '*' : (origin === allowed ? allowed : 'null'),
      'Access-Control-Allow-Methods': 'GET,POST,PATCH,OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type,X-Owner-Token',
      'Vary': 'Origin'
    };
    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers: corsHeaders });
    }

    // Helper: JSON response
    const j = (obj, status = 200, extra = {}) =>
      new Response(JSON.stringify(obj), { status, headers: { 'Content-Type': 'application/json', ...corsHeaders, ...extra } });

    // Route matching under /api
    const path = url.pathname.replace(/\/+$/, '');
    const match = (method, re) => request.method === method && re.test(path);

    // Health
    if (match('GET', /^\/api\/health$/)) {
      return j({ ok: true, ts: Date.now() });
    }

    // Debug auth
    if (match('GET', /^\/api\/debug\/auth$/)) {
      const tok = request.headers.get('X-Owner-Token') || '';
      if (tok && env.OWNER_TOKEN && tok === env.OWNER_TOKEN) return j({ ok: true });
      return j({ ok: false }, 401);
    }

    // Inventory: list
    if (match('GET', /^\/api\/inventory$/)) {
      const rs = await env.DB.prepare(
        "SELECT id, sku, title, category, status, cost_cents, quantity, created_at FROM Inventory ORDER BY created_at DESC LIMIT 100"
      ).all();
      return j(rs.results || []);
    }

    // Inventory: create
    if (match('POST', /^\/api\/inventory$/)) {
      const body = await request.json().catch(() => ({}));
      const id = crypto.randomUUID();
      const sku = String(body.sku || '').trim();
      const title = String(body.title || '').trim();
      const category = String(body.category || '').trim();
      const cost_usd = Number(body.cost_usd || 0);
      const quantity = Number(body.quantity || 1);

      if (!sku || !title || !category) return j({ error: 'sku, title, category required' }, 400);

      const cost_cents = Math.round(cost_usd * 100);
      try {
        await env.DB.prepare(
          "INSERT INTO Inventory (id, sku, title, category, status, cost_cents, quantity) VALUES (?1, ?2, ?3, ?4, 'staged', ?5, ?6)"
        ).bind(id, sku, title, category, cost_cents, quantity).run();
        return j({ id, sku, title, category, status: 'staged', cost_cents, quantity }, 201);
      } catch (e) {
        return j({ error: 'insert_failed', detail: String(e) }, 409);
      }
    }

    // Inventory: patch (owner only)
    const patchMatch = path.match(/^\/api\/inventory\/([^/]+)$/);
    if (request.method === 'PATCH' && patchMatch) {
      const tok = request.headers.get('X-Owner-Token') || '';
      if (!tok || !env.OWNER_TOKEN || tok !== env.OWNER_TOKEN) return j({ error: 'unauthorized' }, 401);

      const id = patchMatch[1];
      const body = await request.json().catch(() => ({}));
      const status = body.status;
      const quantity = typeof body.quantity === 'number' ? Math.max(0, Math.floor(body.quantity)) : undefined;

      if (!status && typeof quantity === 'undefined') return j({ error: 'no_fields' }, 400);

      const sets = [];
      const vals = [];
      if (status) { sets.push("status = ?"); vals.push(String(status)); }
      if (typeof quantity !== 'undefined') { sets.push("quantity = ?"); vals.push(quantity); }

      const sql = `UPDATE Inventory SET ${sets.join(', ')} WHERE id = ?`;
      vals.push(id);

      const res = await env.DB.prepare(sql).bind(...vals).run();
      if (res.meta.changes === 0) return j({ error: 'not_found' }, 404);
      return j({ ok: true });
    }

    // Fallback 404 (with CORS)
    return j({ error: 'not_found' }, 404);
  }
};
