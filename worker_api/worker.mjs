const cors = (allowed, origin) => ({
  'Access-Control-Allow-Origin': allowed === '*' ? '*' : (origin === allowed ? allowed : 'null'),
  'Access-Control-Allow-Methods': 'GET,POST,PATCH,DELETE,OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type,X-Owner-Token',
  'Vary': 'Origin'
});
const j = (obj, status = 200, headers = {}) =>
  new Response(JSON.stringify(obj), { status, headers: { 'Content-Type': 'application/json', ...headers } });

const num = (v, d=0) => { const n = Number(v); return Number.isFinite(n) ? n : d; };
const cents = (usd) => Math.round(num(usd, 0) * 100);

async function findInventoryIdBySku(DB, sku) {
  const rs = await DB.prepare("SELECT id FROM Inventory WHERE sku = ? LIMIT 1").bind(sku).all();
  return rs.results?.[0]?.id || null;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const origin = request.headers.get('Origin') || '*';
    const headers = cors(env.ALLOWED_ORIGIN || '*', origin);

    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers });

    const path = url.pathname.replace(/\/+$/, '');
    const m = (method, re) => request.method === method && re.test(path);

    // Health & auth debug
    if (m('GET', /^\/api\/health$/)) return j({ ok: true, ts: Date.now() }, 200, headers);
    if (m('GET', /^\/api\/debug\/auth$/)) {
      const tok = request.headers.get('X-Owner-Token') || '';
      const ok = !!tok && !!env.OWNER_TOKEN && tok === env.OWNER_TOKEN;
      return j({ ok }, ok ? 200 : 401, headers);
    }

    // Inventory
    if (m('GET', /^\/api\/inventory$/)) {
      const rs = await env.DB.prepare(
        "SELECT id, sku, title, category, status, cost_cents, quantity, created_at FROM Inventory ORDER BY created_at DESC LIMIT 200"
      ).all();
      return j(rs.results || [], 200, headers);
    }
    if (m('POST', /^\/api\/inventory$/)) {
      let b={}; try{ b=await request.json(); }catch{}
      const id=crypto.randomUUID(), sku=String(b.sku||'').trim(), title=String(b.title||'').trim(), category=String(b.category||'').trim();
      const quantity=Math.max(0,Math.floor(num(b.quantity,1))); const cost_cents=cents(b.cost_usd);
      if(!sku||!title||!category) return j({error:'sku/title/category required'},400,headers);
      try{
        await env.DB.prepare("INSERT INTO Inventory (id, sku, title, category, status, cost_cents, quantity) VALUES (?1,?2,?3,?4,'staged',?5,?6)")
          .bind(id,sku,title,category,cost_cents,quantity).run();
        return j({id,sku,title,category,status:'staged',cost_cents,quantity},201,headers);
      }catch(e){ return j({error:'insert_failed',detail:String(e)},409,headers); }
    }
    if (m('PATCH', /^\/api\/inventory\/[^/]+$/)) {
      const tok=request.headers.get('X-Owner-Token')||''; if(!tok||!env.OWNER_TOKEN||tok!==env.OWNER_TOKEN) return j({error:'unauthorized'},401,headers);
      const id = path.split('/').pop(); let b={}; try{ b=await request.json(); }catch{}
      const sets=[], vals=[];
      if (typeof b.status==='string' && b.status) { sets.push("status = ?"); vals.push(b.status); }
      if (typeof b.quantity==='number') { sets.push("quantity = ?"); vals.push(Math.max(0,Math.floor(b.quantity))); }
      if (!sets.length) return j({error:'no_fields'},400,headers);
      const res = await env.DB.prepare(`UPDATE Inventory SET ${sets.join(', ')} WHERE id = ?`).bind(...vals,id).run();
      return res.meta.changes ? j({ok:true},200,headers) : j({error:'not_found'},404,headers);
    }

    // Sales
    if (m('GET', /^\/api\/sales$/)) {
      const from=url.searchParams.get('from'); const to=url.searchParams.get('to');
      const where=[],bind=[]; if(from){where.push("date >= ?");bind.push(from);} if(to){where.push("date <= ?");bind.push(to);}
      const rs = await env.DB.prepare(`SELECT id,date,inventory_id,sku,qty,sold_price_cents,buyer_shipping_cents,platform_fees_cents,promo_fee_cents,shipping_label_cost_cents,other_costs_cents,order_ref,note,created_at FROM Sales ${where.length?"WHERE "+where.join(" AND "):""} ORDER BY date DESC, created_at DESC LIMIT 200`).bind(...bind).all();
      return j(rs.results||[],200,headers);
    }
    if (m('POST', /^\/api\/sales$/)) {
      let b={}; try{ b=await request.json(); }catch{}
      const id=crypto.randomUUID(); const date=String(b.date||'').trim(); const sku=String(b.sku||'').trim(); const qty=Math.max(1,Math.floor(num(b.qty,1)));
      const sold_price_cents=cents(b.sold_price_usd), buyer_shipping_cents=cents(b.buyer_shipping_usd), platform_fees_cents=cents(b.platform_fees_usd), promo_fee_cents=cents(b.promo_fee_usd), shipping_label_cost_cents=cents(b.shipping_label_cost_usd), other_costs_cents=cents(b.other_costs_usd);
      const order_ref=String(b.order_ref||'').trim(); const note=String(b.note||''); const inventory_id=(b.inventory_id||null);
      if(!date||!sku||!order_ref) return j({error:'date/sku/order_ref required'},400,headers);
      await env.DB.prepare(`INSERT INTO Sales (id,date,inventory_id,sku,qty,sold_price_cents,buyer_shipping_cents,platform_fees_cents,promo_fee_cents,shipping_label_cost_cents,other_costs_cents,order_ref,note) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13)`)
        .bind(id,date,inventory_id,sku,qty,sold_price_cents,buyer_shipping_cents,platform_fees_cents,promo_fee_cents,shipping_label_cost_cents,other_costs_cents,order_ref,note).run();
      return j({id,ok:true},201,headers);
    }

    // Expenses
    if (m('GET', /^\/api\/expenses$/)) {
      const from=url.searchParams.get('from'); const to=url.searchParams.get('to');
      const where=[],bind=[]; if(from){where.push("date >= ?");bind.push(from);} if(to){where.push("date <= ?");bind.push(to);}
      const rs = await env.DB.prepare(`SELECT id,date,category,amount_cents,vendor,note,sku,type,miles,rate_cents_per_mile,calc_amount_cents,deductible,created_at FROM Expenses ${where.length?"WHERE "+where.join(" AND "):""} ORDER BY date DESC, created_at DESC LIMIT 200`).bind(...bind).all();
      return j(rs.results||[],200,headers);
    }
    if (m('POST', /^\/api\/expenses$/)) {
      let b={}; try{ b=await request.json(); }catch{}
      const id=crypto.randomUUID(); const date=String(b.date||'').trim(); const category=String(b.category||'').trim();
      const type=String(b.type||'standard'); const vendor=String(b.vendor||''); const note=String(b.note||''); const sku=(b.sku||null);
      const amount_cents=cents(b.amount_usd); const miles=Number.isFinite(num(b.miles))?Math.max(0,Math.floor(num(b.miles))):null; const rate_cents_per_mile=Number.isFinite(num(b.rate_usd_per_mile))?cents(b.rate_usd_per_mile):null; const deductible=(String(b.deductible??'1')==='0')?0:1;
      let calc_amount_cents=null; if(type==='mileage' && miles!==null && rate_cents_per_mile!==null){ calc_amount_cents=miles*rate_cents_per_mile; }
      if(!date||!category) return j({error:'date/category required'},400,headers);
      await env.DB.prepare(`INSERT INTO Expenses (id,date,category,amount_cents,vendor,note,sku,type,miles,rate_cents_per_mile,calc_amount_cents,deductible) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)`)
        .bind(id,date,category,amount_cents,vendor,note,sku,type,miles,rate_cents_per_mile,calc_amount_cents,deductible).run();
      return j({id,ok:true},201,headers);
    }

    // Reports
    if (m('GET', /^\/api\/reports\/summary$/)) {
      const from=url.searchParams.get('from')||'0000-01-01'; const to=url.searchParams.get('to')||'9999-12-31';
      const invCounts = await env.DB.prepare("SELECT status, COUNT(*) as cnt FROM Inventory GROUP BY status").all();
      const salesAgg = await env.DB.prepare(`SELECT COALESCE(SUM(sold_price_cents),0) gross, COALESCE(SUM(buyer_shipping_cents),0) buyer_ship, COALESCE(SUM(platform_fees_cents + promo_fee_cents + shipping_label_cost_cents + other_costs_cents),0) costs, COALESCE(SUM(qty),0) total_qty FROM Sales WHERE date BETWEEN ? AND ?`).bind(from,to).all();
      const expAgg = await env.DB.prepare(`SELECT COALESCE(SUM(amount_cents),0) expenses, COALESCE(SUM(calc_amount_cents),0) mileage FROM Expenses WHERE date BETWEEN ? AND ?`).bind(from,to).all();
      const byStatus = Object.fromEntries((invCounts.results||[]).map(r=>[r.status,r.cnt]));
      const gross=salesAgg.results?.[0]?.gross||0, buyerShip=salesAgg.results?.[0]?.buyer_ship||0, salesCosts=salesAgg.results?.[0]?.costs||0;
      const expenses=expAgg.results?.[0]?.expenses||0, mileage=expAgg.results?.[0]?.mileage||0;
      const revenue=gross+buyerShip, total_exp= salesCosts+expenses+mileage, net=revenue-total_exp;
      return j({inventory_by_status:byStatus,revenue_cents:revenue,total_expenses_cents:total_exp,net_cents:net},200,headers);
    }

    // Lots
    if (m('GET', /^\/api\/lots$/)) {
      const rs = await env.DB.prepare("SELECT id,title,note,status,created_at FROM Lots ORDER BY created_at DESC LIMIT 200").all();
      return j(rs.results||[],200,headers);
    }
    if (m('POST', /^\/api\/lots$/)) {
      let b={}; try{ b=await request.json(); }catch{}
      const id=crypto.randomUUID(); const title=String(b.title||'').trim(); const note=String(b.note||''); const status=String(b.status||'open');
      if(!title) return j({error:'title required'},400,headers);
      if(!['open','closed'].includes(status)) return j({error:'bad status'},400,headers);
      await env.DB.prepare("INSERT INTO Lots (id,title,note,status) VALUES (?1,?2,?3,?4)").bind(id,title,note,status).run();
      return j({id,ok:true},201,headers);
    }
    if (m('PATCH', /^\/api\/lots\/[^/]+$/)) {
      const tok=request.headers.get('X-Owner-Token')||''; if(!tok||!env.OWNER_TOKEN||tok!==env.OWNER_TOKEN) return j({error:'unauthorized'},401,headers);
      const id = path.split('/').pop(); let b={}; try{ b=await request.json(); }catch{}
      const sets=[], vals=[];
      if (typeof b.title==='string' && b.title) { sets.push("title = ?"); vals.push(b.title); }
      if (typeof b.note==='string') { sets.push("note = ?"); vals.push(b.note); }
      if (typeof b.status==='string' && ['open','closed'].includes(b.status)) { sets.push("status = ?"); vals.push(b.status); }
      if (!sets.length) return j({error:'no_fields'},400,headers);
      const res = await env.DB.prepare(`UPDATE Lots SET ${sets.join(', ')} WHERE id = ?`).bind(...vals,id).run();
      return res.meta.changes ? j({ok:true},200,headers) : j({error:'not_found'},404,headers);
    }

    // Lots ↔ Inventory linking
    if (m('GET', /^\/api\/lots\/[^/]+\/items$/)) {
      const lotId = path.split('/')[3];
      const rs = await env.DB.prepare(`
        SELECT i.id, i.sku, i.title, i.category, i.status, i.quantity, i.cost_cents, i.created_at
        FROM InventoryLots il
        JOIN Inventory i ON i.id = il.inventory_id
        WHERE il.lot_id = ?
        ORDER BY i.created_at DESC
        LIMIT 500
      `).bind(lotId).all();
      return j(rs.results || [], 200, headers);
    }

    if (m('POST', /^\/api\/lots\/[^/]+\/items$/)) {
      const tok=request.headers.get('X-Owner-Token')||''; if(!tok||!env.OWNER_TOKEN||tok!==env.OWNER_TOKEN) return j({error:'unauthorized'},401,headers);
      const lotId = path.split('/')[3];
      let b={}; try{ b=await request.json(); }catch{}
      const sku = String(b.sku||'').trim();
      if(!sku) return j({error:'sku required'},400,headers);
      const invId = await findInventoryIdBySku(env.DB, sku);
      if(!invId) return j({error:'inventory_not_found'},404,headers);
      try{ await env.DB.prepare("INSERT INTO InventoryLots (inventory_id, lot_id) VALUES (?1, ?2)").bind(invId, lotId).run(); }catch(e){}
      return j({ok:true, inventory_id: invId, lot_id: lotId}, 201, headers);
    }

    if (m('DELETE', /^\/api\/lots\/[^/]+\/items\/[^/]+$/)) {
      const tok=request.headers.get('X-Owner-Token')||''; if(!tok||!env.OWNER_TOKEN||tok!==env.OWNER_TOKEN) return j({error:'unauthorized'},401,headers);
      const parts = path.split('/');
      const lotId = parts[3], invId = parts[5];
      const res = await env.DB.prepare("DELETE FROM InventoryLots WHERE lot_id = ? AND inventory_id = ?").bind(lotId, invId).run();
      return res.meta.changes ? j({ok:true},200,headers) : j({error:'not_found'},404,headers);
    }

    // ---- Photos (R2) ----

    // List photos by inventory id
    if (m('GET', /^\/api\/inventory\/[^/]+\/photos$/)) {
      const invId = path.split('/')[3];
      const rs = await env.DB.prepare("SELECT id, r2_key, content_type, size_bytes, created_at FROM Photos WHERE inventory_id = ? ORDER BY created_at DESC").bind(invId).all();
      return j(rs.results || [], 200, headers);
    }

    // Upload photo via multipart/form-data { file }
    if (m('POST', /^\/api\/inventory\/[^/]+\/photos$/)) {
      const tok=request.headers.get('X-Owner-Token')||''; if(!tok||!env.OWNER_TOKEN||tok!==env.OWNER_TOKEN) return j({error:'unauthorized'},401,headers);
      const invId = path.split('/')[3];
      const form = await request.formData().catch(()=>null);
      if (!form) return j({error:'form_required'},400,headers);
      const file = form.get('file');
      if (!file || typeof file === 'string') return j({error:'file_required'},400,headers);

      const id = crypto.randomUUID();
      const ext = (file.name?.split('.').pop() || '').toLowerCase();
      const safeName = (file.name || 'upload').replace(/[^a-zA-Z0-9._-]/g,'_');
      const key = `inventory/${invId}/${id}_${safeName}`;
      const contentType = file.type || 'application/octet-stream';
      const size = file.size || 0;

      // Store in R2
      await env.R2.put(key, file.stream(), { httpMetadata: { contentType } });

      // Save metadata
      await env.DB.prepare("INSERT INTO Photos (id, inventory_id, r2_key, content_type, size_bytes) VALUES (?1,?2,?3,?4,?5)")
        .bind(id, invId, key, contentType, size).run();

      return j({ id, key, ok:true }, 201, headers);
    }

    // Stream photo bytes by photo id
    if (m('GET', /^\/api\/photos\/[^/]+$/)) {
      const photoId = path.split('/').pop();
      const rs = await env.DB.prepare("SELECT r2_key, content_type FROM Photos WHERE id = ? LIMIT 1").bind(photoId).all();
      const row = rs.results?.[0];
      if (!row) return j({error:'not_found'},404,headers);
      const obj = await env.R2.get(row.r2_key);
      if (!obj) return j({error:'not_found'},404,headers);
      return new Response(obj.body, { status: 200, headers: { ...headers, 'Content-Type': row.content_type || 'application/octet-stream' } });
    }

    return j({error:'not_found'},404,headers);
  }
};
