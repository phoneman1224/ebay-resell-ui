const API = import.meta.env.VITE_API_BASE || (window.API_BASE ?? '');
const $$ = (sel) => document.querySelector(sel);
const h = (html) => String(html).replace(/[&<>]/g, c=>({ '&':'&amp;','<':'&lt;','>':'&gt;'}[c] || c));
const toast = (node, msg) => { node.textContent = msg; setTimeout(()=>node.textContent='', 2500); };

const tokenKey = 'owner_token';
const getToken = () => localStorage.getItem(tokenKey) || '';
const saveToken = (t) => localStorage.setItem(tokenKey, t);

async function req(path, opt = {}) {
  const hdrs = opt.headers || {};
  if (opt.auth) hdrs['X-Owner-Token'] = getToken();
  const r = await fetch(API + path, { ...opt, headers: hdrs });
  if (!r.ok) throw new Error(`${opt.method||'GET'} ${path} -> ${r.status}`);
  if ((r.headers.get('content-type')||'').includes('application/json')) return await r.json();
  return await r.text();
}
const getJSON = (p)=>req(p);
const postJSON=(p,body)=>req(p,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
const patchJSON=(p,body)=>req(p,{method:'PATCH',headers:{'Content-Type':'application/json'},body:JSON.stringify(body),auth:true});
const del     =(p)=>req(p,{method:'DELETE',auth:true});

/* Tabs */
function activateTab(name){
  document.querySelectorAll('button.tab').forEach(b=>b.classList.toggle('active', b.dataset.tab===name));
  document.querySelectorAll('.tabview').forEach(s=>s.style.display = (s.id===name) ? '' : 'none');
}
function bindTabs(){
  document.querySelectorAll('button.tab').forEach(b=>b.addEventListener('click', ()=>activateTab(b.dataset.tab)));
}

/* Owner token UI */
(function initOwnerToken(){
  const el=$$('#owner-token'), btn=$$('#owner-save');
  if (el) el.value = getToken();
  if (btn) btn.addEventListener('click', ()=>{ saveToken(el.value.trim()); btn.textContent='Saved ✓'; setTimeout(()=>btn.textContent='Save',1200); });
})();

/* Inventory */
async function refreshInv(){
  const list=$$('#inv-list'); list.innerHTML='Loading…';
  try{
    const rows = await getJSON('/inventory');
    list.innerHTML = `<table><thead><tr><th>SKU</th><th>Title</th><th>Cat</th><th>Status</th><th>Qty</th><th>Cost</th><th>Created</th></tr></thead><tbody>${
      rows.map(r=>`<tr><td>${h(r.sku)}</td><td>${h(r.title)}</td><td>${h(r.category)}</td><td>${h(r.status)}</td><td>${r.quantity}</td><td>$${(r.cost_cents/100).toFixed(2)}</td><td>${h(r.created_at)}</td></tr>`).join('')
    }</tbody></table>`;
  }catch(e){ list.textContent = e.message; }
}
function bindInventory(){
  function $(s){return document.querySelector(s);}
  $$('#inv-create').addEventListener('click', async ()=>{
    const body={sku:$('#inv-sku').value.trim(), title:$('#inv-title').value.trim(), category:$('#inv-category').value.trim(), cost_usd:parseFloat($('#inv-cost').value||'0'), quantity:parseInt($('#inv-qty').value||'1',10)};
    const msg=$$('#inv-list');
    try{ await postJSON('/inventory',body); await refreshInv(); toast(msg,'Created ✓'); }catch(e){ toast(msg,e.message); }
  });
  $$('#inv-refresh').addEventListener('click', refreshInv);
  refreshInv();
}

/* Sales */
async function refreshSales(){
  const el=$$('#sales-list'); el.textContent='Loading…';
  try{
    const rows = await getJSON('/sales');
    el.innerHTML = `<table><thead><tr><th>Date</th><th>SKU</th><th>Qty</th><th>Sold</th><th>Buyer Ship</th><th>Fees+</th><th>Order</th></tr></thead><tbody>${
      rows.map(r=>`<tr><td>${h(r.date)}</td><td>${h(r.sku)}</td><td>${r.qty}</td><td>$${(r.sold_price_cents/100).toFixed(2)}</td><td>$${(r.buyer_shipping_cents/100).toFixed(2)}</td><td>$${((r.platform_fees_cents + r.promo_fee_cents + r.shipping_label_cost_cents + r.other_costs_cents)/100).toFixed(2)}</td><td>${h(r.order_ref)}</td></tr>`).join('')
    }</tbody></table>`;
  }catch(e){ el.textContent=e.message; }
}
function bindSales(){
  function $(s){return document.querySelector(s);}
  $$('#s-create').addEventListener('click', async ()=>{
    const body = {
      date:$('#s-date').value.trim(),
      sku:$('#s-sku').value.trim(),
      qty:parseInt($('#s-qty').value||'1',10),
      sold_price_usd:parseFloat($('#s-price').value||'0'),
      buyer_shipping_usd:parseFloat($('#s-bship').value||'0'),
      platform_fees_usd:parseFloat($('#s-fees').value||'0'),
      promo_fee_usd:parseFloat($('#s-promo').value||'0'),
      shipping_label_cost_usd:parseFloat($('#s-shipcost').value||'0'),
      other_costs_usd:parseFloat($('#s-other').value||'0'),
      order_ref:$('#s-ref').value.trim(),
      note:$('#s-note').value
    };
    const msg=$$('#sales-list');
    try{ await postJSON('/sales', body); await refreshSales(); toast(msg,'Sale saved ✓'); }catch(e){ toast(msg, e.message); }
  });
  $$('#s-refresh').addEventListener('click', refreshSales);
  refreshSales();
}

/* Expenses */
async function refreshExp(){
  const el=$$('#exp-list'); el.textContent='Loading…';
  try{
    const rows = await getJSON('/expenses');
    el.innerHTML = `<table><thead><tr><th>Date</th><th>Category</th><th>Type</th><th>Amount</th><th>Miles</th><th>Rate</th></tr></thead><tbody>${
      rows.map(r=>`<tr><td>${h(r.date)}</td><td>${h(r.category)}</td><td>${h(r.type)}</td><td>$${(r.amount_cents/100).toFixed(2)}</td><td>${r.miles ?? ''}</td><td>${r.rate_cents_per_mile? '$'+(r.rate_cents_per_mile/100).toFixed(2):''}</td></tr>`).join('')
    }</tbody></table>`;
  }catch(e){ el.textContent=e.message; }
}
function bindExpenses(){
  function $(s){return document.querySelector(s);}
  $$('#e-create').addEventListener('click', async ()=>{
    const body = {
      date:$('#e-date').value.trim(),
      category:$('#e-cat').value.trim(),
      type:$('#e-type').value,
      amount_usd:parseFloat($('#e-amt').value||'0'),
      vendor:$('#e-vendor').value.trim(),
      sku:$('#e-sku').value.trim() || null,
      miles:parseInt($('#e-miles').value||'0',10),
      rate_usd_per_mile:parseFloat($('#e-rate').value||'0'),
      deductible:parseInt($('#e-deduct').value,10),
      note:$('#e-note').value
    };
    const msg=$$('#exp-list');
    try{ await postJSON('/expenses', body); await refreshExp(); toast(msg,'Expense saved ✓'); }catch(e){ toast(msg, e.message); }
  });
  $$('#e-refresh').addEventListener('click', refreshExp);
  refreshExp();
}

/* Lots + Linking */
let currentLotId = null;
function setCurrentLot(id){
  currentLotId = id || null;
  if (currentLotId) refreshLotItems();
  else $$('#li-list').textContent = 'Select a lot to see items…';
}
async function refreshLots(){
  const el=$$('#l-list'); el.textContent='Loading…';
  try{
    const rows = await getJSON('/lots');
    el.innerHTML = `<table><thead><tr><th>Title</th><th>Status</th><th>Note</th><th>Created</th><th></th></tr></thead><tbody>${
      rows.map(r=>`<tr><td>${h(r.title)}</td><td>${h(r.status)}</td><td>${h(r.note||'')}</td><td>${h(r.created_at)}</td><td><button class="btn secondary" data-id="${h(r.id)}">Select</button></td></tr>`).join('')
    }</tbody></table>`;
    el.querySelectorAll('button[data-id]').forEach(btn=>{
      btn.addEventListener('click', ()=> setCurrentLot(btn.getAttribute('data-id')));
    });
  }catch(e){ el.textContent=e.message; }
}
async function refreshLotItems(){
  const el = $$('#li-list');
  if (!currentLotId) { el.textContent='Select a lot…'; return; }
  el.textContent='Loading…';
  try{
    const rows = await getJSON(`/lots/${encodeURIComponent(currentLotId)}/items`);
    el.innerHTML = `<table><thead><tr><th>SKU</th><th>Title</th><th>Status</th><th>Qty</th><th>Cost</th><th>Created</th><th></th></tr></thead><tbody>${
      rows.map(r=>`<tr><td>${h(r.sku)}</td><td>${h(r.title)}</td><td>${h(r.status)}</td><td>${r.quantity}</td><td>$${(r.cost_cents/100).toFixed(2)}</td><td>${h(r.created_at)}</td><td><button class="btn secondary" data-rm="${h(r.id)}">Remove</button></td></tr>`).join('')
    }</tbody></table>`;
    el.querySelectorAll('button[data-rm]').forEach(btn=>{
      btn.addEventListener('click', async ()=>{
        try{
          await del(`/lots/${encodeURIComponent(currentLotId)}/items/${encodeURIComponent(btn.getAttribute('data-rm'))}`);
          await refreshLotItems();
        }catch(e){ toast(el, e.message); }
      });
    });
  }catch(e){ el.textContent=e.message; }
}
function bindLots(){
  function $(s){return document.querySelector(s);}
  $$('#l-create').addEventListener('click', async ()=>{
    const body={ title:$('#l-title').value.trim(), note:$('#l-note').value, status:$('#l-status').value };
    const msg=$$('#l-list');
    try{ const r=await postJSON('/lots', body); await refreshLots(); setCurrentLot(r.id); toast(msg,'Lot created ✓'); }catch(e){ toast(msg, e.message); }
  });
  $$('#l-refresh').addEventListener('click', refreshLots);
  $$('#li-add').addEventListener('click', async ()=>{
    const sku = $$('#li-sku').value.trim();
    const msg = $$('#li-list');
    if (!currentLotId) { toast(msg, 'Select a lot first'); return; }
    try{
      await postJSON(`/lots/${encodeURIComponent(currentLotId)}/items`, { sku });
      $$('#li-sku').value='';
      await refreshLotItems();
      toast(msg,'Added ✓');
    }catch(e){ toast(msg, e.message); }
  });
  refreshLots();
}

/* Photos (by SKU) */
function bindPhotos(){
  async function inventoryIdBySku(sku){
    const rows = await getJSON('/inventory');
    const row = rows.find(r=>String(r.sku).trim().toLowerCase() === sku.trim().toLowerCase());
    return row ? row.id : null;
  }
  async function refreshThumbs(){
    const sku = $$('#ph-sku').value.trim();
    const grid = $$('#ph-thumbs'); grid.innerHTML = '';
    if (!sku) { grid.innerHTML = '<div class="muted">Enter a SKU to view photos.</div>'; return; }
    const invId = await inventoryIdBySku(sku);
    if (!invId) { grid.innerHTML = '<div class="muted">SKU not found.</div>'; return; }
    const list = await getJSON(`/inventory/${encodeURIComponent(invId)}/photos`);
    if (!list.length) { grid.innerHTML = '<div class="muted">No photos yet.</div>'; return; }
    grid.innerHTML = list.map(p=>`<a href="${API}/photos/${p.id}" target="_blank"><img src="${API}/photos/${p.id}" alt="${h(p.r2_key)}"/></a>`).join('');
  }

  $$('#ph-upload').addEventListener('click', async ()=>{
    const sku = $$('#ph-sku').value.trim();
    const file = $$('#ph-file').files[0];
    const grid = $$('#ph-thumbs');
    if (!sku) { toast(grid, 'Enter a SKU'); return; }
    if (!file) { toast(grid, 'Choose a file'); return; }
    const invId = await inventoryIdBySku(sku);
    if (!invId) { toast(grid, 'SKU not found'); return; }
    const fd = new FormData(); fd.append('file', file, file.name);
    try{
      await fetch(API + `/inventory/${encodeURIComponent(invId)}/photos`, {
        method:'POST', body:fd, headers:{ 'X-Owner-Token': localStorage.getItem('owner_token') || '' }
      }).then(r=>{ if(!r.ok) throw new Error('Upload failed '+r.status); });
      toast(grid, 'Uploaded ✓'); await refreshThumbs();
    }catch(e){ toast(grid, e.message); }
  });
  $$('#ph-refresh').addEventListener('click', bindPhotos.refreshThumbs = refreshThumbs);
  bindPhotos.refreshThumbs = refreshThumbs;
}
function bindPhotosBoot(){ if (bindPhotos.refreshThumbs) bindPhotos.refreshThumbs(); }

/* Reports */
function bindReports(){
  $$('#r-run').addEventListener('click', async ()=>{
    const from=$$('#r-from').value.trim(), to=$$('#r-to').value.trim();
    const q=new URLSearchParams(); if(from) q.set('from',from); if(to) q.set('to',to);
    const out=$$('#r-out');
    try{
      const r = await getJSON('/reports/summary' + (q.toString()?`?${q.toString()}`:''));
      const money = n => `$${(n/100).toFixed(2)}`;
      out.textContent =
`Inventory by status: ${JSON.stringify(r.inventory_by_status)}
Revenue:  ${money(r.revenue_cents)}
Expenses: ${money(r.total_expenses_cents)}
Net:      ${money(r.net_cents)}`;
    }catch(e){ out.textContent = e.message; }
  });
}

/* Boot */
document.addEventListener('DOMContentLoaded', ()=>{
  document.querySelectorAll('button.tab').forEach(b=>b.addEventListener('click', ()=>activateTab(b.dataset.tab)));
  // bind all
  bindTabs();
  bindInventory();
  bindSales();
  bindExpenses();
  bindLots();
  bindReports();
  bindPhotos();
  bindPhotosBoot();
});
