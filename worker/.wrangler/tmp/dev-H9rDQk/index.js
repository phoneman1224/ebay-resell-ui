var __defProp = Object.defineProperty;
var __name = (target, value) => __defProp(target, "name", { value, configurable: true });

// src/index.ts
var cors = /* @__PURE__ */ __name((origin) => ({
  "access-control-allow-origin": origin && origin !== "*" ? origin : "*",
  "access-control-allow-methods": "GET,POST,OPTIONS",
  "access-control-allow-headers": "content-type,authorization,idempotency-key",
  "vary": "origin"
}), "cors");
var json = /* @__PURE__ */ __name((data, init = {}, origin = "*") => new Response(JSON.stringify(data), {
  status: init.status ?? 200,
  headers: {
    "content-type": "application/json; charset=utf-8",
    ...cors(origin),
    ...init.headers ?? {}
  }
}), "json");
var err = /* @__PURE__ */ __name((code, message, details) => ({ error: { code, message, details } }), "err");
async function readBody(req) {
  try {
    const text = await req.text();
    if (!text) return null;
    return JSON.parse(text);
  } catch {
    return null;
  }
}
__name(readBody, "readBody");
var src_default = {
  async fetch(req, env) {
    if (req.method === "OPTIONS") {
      return new Response(null, { headers: cors(env.ALLOWED_ORIGIN) });
    }
    const url = new URL(req.url);
    const p = url.pathname.replace(/\/$/, "");
    if (req.method === "GET" && p === "/api/health") {
      try {
        await env.DB.prepare("SELECT 1").first();
      } catch (e) {
        return json(err("db_unavailable", e?.message ?? "DB error"), { status: 500 }, env.ALLOWED_ORIGIN);
      }
      return json({ ok: true }, {}, env.ALLOWED_ORIGIN);
    }
    if (req.method === "GET" && p === "/api/inventory") {
      const q = (url.searchParams.get("q") || "").trim();
      let stmt = "SELECT id, sku, title, category, status, cost_cents, quantity, created_at FROM Inventory";
      const params = [];
      if (q) {
        stmt += " WHERE sku LIKE ? OR title LIKE ?";
        params.push(`%${q}%`, `%${q}%`);
      }
      stmt += " ORDER BY created_at DESC LIMIT 100";
      const rows = await env.DB.prepare(stmt).bind(...params).all();
      return json({ items: rows.results ?? [] }, {}, env.ALLOWED_ORIGIN);
    }
    if (req.method === "POST" && p === "/api/inventory") {
      const auth = req.headers.get("authorization") || "";
      const token = auth.toLowerCase().startsWith("bearer ") ? auth.slice(7) : auth;
      if (env.OWNER_TOKEN && token !== env.OWNER_TOKEN) {
        return json(err("unauthorized", "Invalid OWNER_TOKEN"), { status: 401 }, env.ALLOWED_ORIGIN);
      }
      const body = await readBody(req);
      if (!body || !body.sku || !body.title) {
        return json(err("bad_request", "`sku` and `title` are required"), { status: 400 }, env.ALLOWED_ORIGIN);
      }
      const sku = String(body.sku).trim();
      const title = String(body.title).trim();
      const category = String(body.category || "Misc");
      const cost_cents = Math.round(Number(body.cost_usd ?? 0) * 100);
      const quantity = Number.isFinite(body.quantity) ? Number(body.quantity) : 1;
      const id = crypto.randomUUID();
      const now = (/* @__PURE__ */ new Date()).toISOString();
      try {
        await env.DB.prepare(
          "INSERT INTO Inventory (id, sku, title, category, status, cost_cents, quantity, created_at) VALUES (?, ?, ?, ?, 'staged', ?, ?, ?)"
        ).bind(id, sku, title, category, cost_cents, quantity, now).run();
      } catch (e) {
        if (/UNIQUE/i.test(String(e?.message))) {
          return json(err("conflict", "SKU already exists"), { status: 409 }, env.ALLOWED_ORIGIN);
        }
        return json(err("internal", e?.message || "Unexpected error"), { status: 500 }, env.ALLOWED_ORIGIN);
      }
      return json({ id, sku, title, category, status: "staged", cost_cents, quantity, created_at: now }, { status: 201 }, env.ALLOWED_ORIGIN);
    }
    return json(err("not_found", "Route not found"), { status: 404 }, env.ALLOWED_ORIGIN);
  }
};

// ../../../.nvm/versions/node/v22.19.0/lib/node_modules/wrangler/templates/middleware/middleware-ensure-req-body-drained.ts
var drainBody = /* @__PURE__ */ __name(async (request, env, _ctx, middlewareCtx) => {
  try {
    return await middlewareCtx.next(request, env);
  } finally {
    try {
      if (request.body !== null && !request.bodyUsed) {
        const reader = request.body.getReader();
        while (!(await reader.read()).done) {
        }
      }
    } catch (e) {
      console.error("Failed to drain the unused request body.", e);
    }
  }
}, "drainBody");
var middleware_ensure_req_body_drained_default = drainBody;

// ../../../.nvm/versions/node/v22.19.0/lib/node_modules/wrangler/templates/middleware/middleware-miniflare3-json-error.ts
function reduceError(e) {
  return {
    name: e?.name,
    message: e?.message ?? String(e),
    stack: e?.stack,
    cause: e?.cause === void 0 ? void 0 : reduceError(e.cause)
  };
}
__name(reduceError, "reduceError");
var jsonError = /* @__PURE__ */ __name(async (request, env, _ctx, middlewareCtx) => {
  try {
    return await middlewareCtx.next(request, env);
  } catch (e) {
    const error = reduceError(e);
    return Response.json(error, {
      status: 500,
      headers: { "MF-Experimental-Error-Stack": "true" }
    });
  }
}, "jsonError");
var middleware_miniflare3_json_error_default = jsonError;

// .wrangler/tmp/bundle-BNMPls/middleware-insertion-facade.js
var __INTERNAL_WRANGLER_MIDDLEWARE__ = [
  middleware_ensure_req_body_drained_default,
  middleware_miniflare3_json_error_default
];
var middleware_insertion_facade_default = src_default;

// ../../../.nvm/versions/node/v22.19.0/lib/node_modules/wrangler/templates/middleware/common.ts
var __facade_middleware__ = [];
function __facade_register__(...args) {
  __facade_middleware__.push(...args.flat());
}
__name(__facade_register__, "__facade_register__");
function __facade_invokeChain__(request, env, ctx, dispatch, middlewareChain) {
  const [head, ...tail] = middlewareChain;
  const middlewareCtx = {
    dispatch,
    next(newRequest, newEnv) {
      return __facade_invokeChain__(newRequest, newEnv, ctx, dispatch, tail);
    }
  };
  return head(request, env, ctx, middlewareCtx);
}
__name(__facade_invokeChain__, "__facade_invokeChain__");
function __facade_invoke__(request, env, ctx, dispatch, finalMiddleware) {
  return __facade_invokeChain__(request, env, ctx, dispatch, [
    ...__facade_middleware__,
    finalMiddleware
  ]);
}
__name(__facade_invoke__, "__facade_invoke__");

// .wrangler/tmp/bundle-BNMPls/middleware-loader.entry.ts
var __Facade_ScheduledController__ = class ___Facade_ScheduledController__ {
  constructor(scheduledTime, cron, noRetry) {
    this.scheduledTime = scheduledTime;
    this.cron = cron;
    this.#noRetry = noRetry;
  }
  static {
    __name(this, "__Facade_ScheduledController__");
  }
  #noRetry;
  noRetry() {
    if (!(this instanceof ___Facade_ScheduledController__)) {
      throw new TypeError("Illegal invocation");
    }
    this.#noRetry();
  }
};
function wrapExportedHandler(worker) {
  if (__INTERNAL_WRANGLER_MIDDLEWARE__ === void 0 || __INTERNAL_WRANGLER_MIDDLEWARE__.length === 0) {
    return worker;
  }
  for (const middleware of __INTERNAL_WRANGLER_MIDDLEWARE__) {
    __facade_register__(middleware);
  }
  const fetchDispatcher = /* @__PURE__ */ __name(function(request, env, ctx) {
    if (worker.fetch === void 0) {
      throw new Error("Handler does not export a fetch() function.");
    }
    return worker.fetch(request, env, ctx);
  }, "fetchDispatcher");
  return {
    ...worker,
    fetch(request, env, ctx) {
      const dispatcher = /* @__PURE__ */ __name(function(type, init) {
        if (type === "scheduled" && worker.scheduled !== void 0) {
          const controller = new __Facade_ScheduledController__(
            Date.now(),
            init.cron ?? "",
            () => {
            }
          );
          return worker.scheduled(controller, env, ctx);
        }
      }, "dispatcher");
      return __facade_invoke__(request, env, ctx, dispatcher, fetchDispatcher);
    }
  };
}
__name(wrapExportedHandler, "wrapExportedHandler");
function wrapWorkerEntrypoint(klass) {
  if (__INTERNAL_WRANGLER_MIDDLEWARE__ === void 0 || __INTERNAL_WRANGLER_MIDDLEWARE__.length === 0) {
    return klass;
  }
  for (const middleware of __INTERNAL_WRANGLER_MIDDLEWARE__) {
    __facade_register__(middleware);
  }
  return class extends klass {
    #fetchDispatcher = /* @__PURE__ */ __name((request, env, ctx) => {
      this.env = env;
      this.ctx = ctx;
      if (super.fetch === void 0) {
        throw new Error("Entrypoint class does not define a fetch() function.");
      }
      return super.fetch(request);
    }, "#fetchDispatcher");
    #dispatcher = /* @__PURE__ */ __name((type, init) => {
      if (type === "scheduled" && super.scheduled !== void 0) {
        const controller = new __Facade_ScheduledController__(
          Date.now(),
          init.cron ?? "",
          () => {
          }
        );
        return super.scheduled(controller);
      }
    }, "#dispatcher");
    fetch(request) {
      return __facade_invoke__(
        request,
        this.env,
        this.ctx,
        this.#dispatcher,
        this.#fetchDispatcher
      );
    }
  };
}
__name(wrapWorkerEntrypoint, "wrapWorkerEntrypoint");
var WRAPPED_ENTRY;
if (typeof middleware_insertion_facade_default === "object") {
  WRAPPED_ENTRY = wrapExportedHandler(middleware_insertion_facade_default);
} else if (typeof middleware_insertion_facade_default === "function") {
  WRAPPED_ENTRY = wrapWorkerEntrypoint(middleware_insertion_facade_default);
}
var middleware_loader_entry_default = WRAPPED_ENTRY;
export {
  __INTERNAL_WRANGLER_MIDDLEWARE__,
  middleware_loader_entry_default as default
};
//# sourceMappingURL=index.js.map
