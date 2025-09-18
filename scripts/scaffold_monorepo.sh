#!/usr/bin/env bash
# Scaffold the missing "worker/" backend for the eBay Resell monorepo.
# Safe, idempotent: will create files only if they don't exist.
# Usage:
#   chmod +x scripts/scaffold_monorepo.sh
#   scripts/scaffold_monorepo.sh
#   # then run autopilot:
#   scripts/autopilot.sh bootstrap

set -Eeuo pipefail
ROOT="${ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$ROOT"

mkdir -p worker/src ui || true

# --- worker/wrangler.toml ---
if [[ ! -f worker/wrangler.toml ]]; then
cat > worker/wrangler.toml <<'TOML'
name = "resell-api"
main = "src/index.ts"
compatibility_date = "2024-11-06"

[vars]
ALLOWED_ORIGIN = "*"
OWNER_TOKEN = "change-me"
JWT_SECRET = "dev-not-used"
ENCRYPTION_KEY = "dev-not-used"

[[d1_databases]]
binding = "DB"
database_name = "resellapp"
database_id = "__REPLACE_WITH_D1_ID__"

[[r2_buckets]]
binding = "R2"
bucket_name = "resell-photos"

[[kv_namespaces]]
binding = "KV"
id = "__REPLACE_WITH_KV_ID__"

[observability]
enabled = true
TOML
fi

# --- worker/package.json ---
if [[ ! -f worker/package.json ]]; then
cat > worker/package.json <<'JSON'
{
  "name": "resell-api",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "wrangler dev --persist-to=./.wrangler/state --local",
    "deploy": "wrangler deploy",
    "migrate": "wrangler d1 execute resellapp --file=./schema.sql"
  },
  "devDependencies": {
    "wrangler": "^3.80.0",
    "typescript": "^5.4.0",
    "@cloudflare/workers-types": "^4.20240512.0"
  }
}
JSON
fi

# --- worker/tsconfig.json ---
if [[ ! -f worker/tsconfig.json ]]; then
cat > worker/tsconfig.json <<'JSON'
{
  "compilerOptions": {
    "target": "ES2022",
    "lib": ["ES2022"],
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "strict": true,
    "noEmit": true,
    "types": ["@cloudflare/workers-types"]
  }
}
JSON
fi

# --- worker/schema.sql ---
if [[ ! -f worker/schema.sql ]]; then
cat > worker/schema.sql <<'SQL'
CREATE TABLE IF NOT EXISTS Inventory (
  id TEXT PRIMARY KEY,
  sku TEXT UNIQUE NOT NULL,
  title TEXT NOT NULL,
  category TEXT NOT NULL,
  status TEXT NOT NULL CHECK(status IN ('staged','draft','active','sold')),
  cost_cents INTEGER NOT NULL DEFAULT 0,
  quantity INTEGER NOT NULL DEFAULT 0,
  listed_date TEXT NULL,
  draft_created_at TEXT NULL,
  created_at TEXT DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_inventory_sku ON Inventory(sku);
CREATE INDEX IF NOT EXISTS idx_inventory_status ON Inventory(status);

CREATE TABLE IF NOT EXISTS Sales (
  id TEXT PRIMARY KEY,
  date TEXT NOT NULL,
  inventory_id TEXT NULL,
  sku TEXT NOT NULL,
  qty INTEGER NOT NULL,
  sold_price_cents INTEGER NOT NULL,
  buyer_shipping_cents INTEGER NOT NULL DEFAULT 0,
  platform_fees_cents INTEGER NOT NULL DEFAULT 0,
  promo_fee_cents INTEGER NOT NULL DEFAULT 0,
  shipping_label_cost_cents INTEGER NOT NULL DEFAULT 0,
  other_costs_cents INTEGER NOT NULL DEFAULT 0,
  order_ref TEXT NOT NULL,
  note TEXT NULL,
  created_at TEXT DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_sales_date ON Sales(date);
CREATE INDEX IF NOT EXISTS idx_sales_sku ON Sales(sku);

CREATE TABLE IF NOT EXISTS Expenses (
  id TEXT PRIMARY KEY,
  date TEXT NOT NULL,
  category TEXT NOT NULL,
  amount_cents INTEGER NOT NULL,
  vendor TEXT NULL,
  note TEXT NULL,
  sku TEXT NULL,
  type TEXT NOT NULL DEFAULT 'standard',
  miles INTEGER NULL,
  rate_cents_per_mile INTEGER NULL,
  calc_amount_cents INTEGER NULL,
  deductible INTEGER NOT NULL DEFAULT 1,
  created_at TEXT DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_expenses_date ON Expenses(date);
CREATE INDEX IF NOT EXISTS idx_expenses_category ON Expenses(category);

DROP VIEW IF EXISTS sales_profit_v;
CREATE VIEW sales_profit_v AS
SELECT
  s.id,
  s.date,
  COALESCE(s.sku, i.sku) AS sku,
  i.title,
  s.qty,
  (s.sold_price_cents + COALESCE(s.buyer_shipping_cents,0)) AS revenue_cents,
  ((COALESCE(i.cost_cents,0)) * s.qty) AS cogs_cents,
  COALESCE(s.platform_fees_cents,0) AS fees_cents,
  COALESCE(s.promo_fee_cents,0) AS promo_fee_cents,
  COALESCE(s.shipping_label_cost_cents,0) AS ship_label_cents,
  COALESCE(s.other_costs_cents,0) AS other_costs_cents,
  ((s.sold_price_cents + COALESCE(s.buyer_shipping_cents,0))
   - COALESCE(s.platform_fees_cents,0)
   - COALESCE(s.promo_fee_cents,0)
   - COALESCE(s.shipping_label_cost_cents,0)
   - COALESCE(s.other_costs_cents,0)
   - ((COALESCE(i.cost_cents,0)) * s.qty)) AS gross_profit_cents
FROM Sales s
LEFT JOIN Inventory i ON (s.inventory_id = i.id) OR (s.sku = i.sku);
SQL
fi

# --- worker/src/index.ts ---
if [[ ! -f worker/src/index.ts ]]; then
cat > worker/src/index.ts <<'TS'
// Minimal API for health and inventory

type Env = { DB: D1Database; R2: R2Bucket; KV: KVNamespace; ALLOWED_ORIGIN: string; OWNER_TOKEN: string };

const cors = (origin?: string) => ({
  "access-control-allow-origin": origin || "*",
  "access-control-allow-methods": "GET,POST,OPTIONS",
  "access-control-allow-headers": "content-type,authorization,idempotency-key",
});

const json = (data: unknown, init: ResponseInit = {}) => new Response(JSON.stringify(data), { status: init.status ?? 200, headers: { 'content-type':'application/json; charset=utf-8', ...cors() } });
const error = (code: string, msg: string, details?: unknown) => ({ error: { code, message: msg, details } });

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    if (req.method === 'OPTIONS') return new Response(null, { headers: cors(env.ALLOWED_ORIGIN) });
    const url = new URL(req.url); const p = url.pathname.replace(/\/$/, '');

    if (p === '/api/health' && req.method === 'GET') {
      const row = await env.DB.prepare('SELECT 1 AS up').first<{ up: number }>();
      return json({ ok: true, up: row?.up === 1 });
    }

    if (p === '/api/inventory' && req.method === 'GET') {
      const fields = ['id','sku','title','category','status','cost_cents','quantity','created_at'];
      const rows = await env.DB.prepare(`SELECT ${fields.join(',')} FROM Inventory ORDER BY created_at DESC LIMIT 200`).all();
      return json({ items: rows.results });
    }

    if (p === '/api/inventory' && req.method === 'POST') {
      const token = (req.headers.get('authorization')||'').replace(/^Bearer\s+/i,'');
      if (!token || token !== env.OWNER_TOKEN) return json(error('unauthorized','Missing/invalid bearer token'), { status: 401 });
      const idem = req.headers.get('idempotency-key'); if (!idem) return json(error('idempotency_required','Idempotency-Key is required'), { status: 400 });
      const body = await req.json().catch(()=>({}));
      const sku = String(body.sku||'').trim().toUpperCase(); const title = String(body.title||'').trim();
      if (!sku || !title) return json(error('validation','sku and title are required'), { status: 400 });
      const cost_cents = Math.round(Number(body.cost_usd ?? 0) * 100);
      const id = crypto.randomUUID(); const now = new Date().toISOString();
      try {
        await env.DB.prepare('INSERT INTO Inventory (id, sku, title, category, status, cost_cents, quantity, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)')
          .bind(id, sku, title, String(body.category||'Misc'), 'staged', cost_cents, Number(body.quantity??1), now).run();
      } catch (e: any) {
        if (/UNIQUE/i.test(String(e?.message))) return json(error('conflict','SKU already exists'), { status: 409 });
        return json(error('internal', e?.message||'Unexpected error'), { status: 500 });
      }
      return json({ id, sku, title, category: String(body.category||'Misc'), status: 'staged', cost_cents, quantity: Number(body.quantity??1), created_at: now }, { status: 201 });
    }

    return json(error('not_found','Route not found'), { status: 404 });
  }
}
TS
fi

# --- ui placeholder (only if ui is empty) ---
if [[ -d ui && ! -e ui/package.json ]]; then
cat > ui/package.json <<'JSON'
{
  "name": "ebay-resell-ui",
  "private": true,
  "version": "0.1.0",
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "vite build",
    "preview": "vite preview --port 5173"
  },
  "dependencies": {
    "react": "^18.3.1",
    "react-dom": "^18.3.1"
  },
  "devDependencies": {
    "@types/react": "^18.3.3",
    "@types/react-dom": "^18.3.0",
    "autoprefixer": "^10.4.19",
    "postcss": "^8.4.38",
    "tailwindcss": "^3.4.7",
    "typescript": "^5.4.0",
    "vite": "^5.4.0"
  }
}
JSON
fi

printf "\nScaffold check complete.\n- worker/: %s\n- ui/: %s\n" \
  "$( [ -f worker/wrangler.toml ] && echo 'ready' || echo 'missing' )" \
  "$( [ -f ui/package.json ] && echo 'present' || echo 'created (minimal)' )"
