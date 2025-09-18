-- Inventory
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

-- Sales (optional but useful)
CREATE TABLE IF NOT EXISTS Sales (
  id TEXT PRIMARY KEY,
  inventory_id TEXT NULL,
  sku TEXT NOT NULL,
  qty INTEGER NOT NULL DEFAULT 1,
  sold_price_cents INTEGER NOT NULL,
  buyer_shipping_cents INTEGER NOT NULL DEFAULT 0,
  platform_fees_cents INTEGER NOT NULL DEFAULT 0,
  promo_fee_cents INTEGER NOT NULL DEFAULT 0,
  shipping_label_cost_cents INTEGER NOT NULL DEFAULT 0,
  other_costs_cents INTEGER NOT NULL DEFAULT 0,
  sold_date TEXT NOT NULL,
  created_at TEXT DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (inventory_id) REFERENCES Inventory(id)
);
CREATE INDEX IF NOT EXISTS idx_sales_sku ON Sales(sku);
CREATE INDEX IF NOT EXISTS idx_sales_date ON Sales(sold_date);

-- Sales view with basic P&L
DROP VIEW IF EXISTS SalesReport;
CREATE VIEW SalesReport AS
SELECT
  s.id,
  s.sku,
  s.qty,
  s.sold_date,
  (s.sold_price_cents + COALESCE(s.buyer_shipping_cents,0)) AS revenue_cents,
  COALESCE(i.cost_cents,0) * s.qty AS cogs_cents,
  COALESCE(s.platform_fees_cents,0) AS fees_cents,
  COALESCE(s.promo_fee_cents,0) AS promo_fee_cents,
  COALESCE(s.shipping_label_cost_cents,0) AS ship_label_cents,
  COALESCE(s.other_costs_cents,0) AS other_costs_cents,
  ( (s.sold_price_cents + COALESCE(s.buyer_shipping_cents,0))
    - COALESCE(s.platform_fees_cents,0)
    - COALESCE(s.promo_fee_cents,0)
    - COALESCE(s.shipping_label_cost_cents,0)
    - COALESCE(s.other_costs_cents,0)
    - (COALESCE(i.cost_cents,0) * s.qty)
  ) AS gross_profit_cents
FROM Sales s
LEFT JOIN Inventory i ON (s.inventory_id = i.id) OR (s.sku = i.sku);
