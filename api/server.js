import express from "express";
import { createClient } from "@supabase/supabase-js";
import { createClient as createRedisClient } from "redis";

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY;
const PORT = Number(process.env.PORT || 3000);
const REDIS_URL = process.env.REDIS_URL || "redis://127.0.0.1:6379";
const CACHE_TTL_SECONDS = 60;

if (!SUPABASE_URL || !SUPABASE_ANON_KEY) {
  throw new Error("Faltan SUPABASE_URL y SUPABASE_ANON_KEY en api/.env");
}

const PRODUCT_TABLES = {
  "ACEITE CASTROL EDGE": "id, marca, tipo, presentacion, viscosidad, precio, stock",
  "ACEITE CASTROL GTX MINERAL": "id, marca, tipo, presentacion, viscosidad, precio, stock",
  "ACEITE CASTROL GTX SINTETICO": "id, marca, tipo, presentacion, viscosidad, precio, stock",
  "ACEITE MOBIL BLEND": "id, marca, tipo, presentacion, viscosidad, stock, precio",
  "ACEITE MOBIL PEGASSO": "id, marca, tipo, presentacion, viscosidad, stock, precio",
  "ACEITE MOBIL NACIONAL": "id, marca, tipo, presentacion, viscosidad, stock, precio",
  "ACEITE MOBIL 1": "id, marca, tipo, presentacion, viscosidad, stock, precio",
  "ACEITE MOBIL DELVAC": "id, marca, tipo, presentacion, viscosidad, stock, precio",
  "LIMPIAPARABRISAS BRONX": "id, marca, medida, presentacion, stock, precio",
  "LIMPIAPARABRISAS RACING": "id, marca, medida, presentacion, stock, precio",
  "BUJIAS": "id, marca, codigo, precio, stock",
  "CUBREVOLANTES": "id, material, precio, stock",
  "FILTROS": "id, codigo, tipo, precio, stock",
  "TAPETES": "id, presentacion, color, piezas, precio, stock"
};

const INVOICE_TABLE = "facturas";
const INVOICE_STATUSES = new Set(["creada", "en_progreso", "aprobada"]);

const app = express();
app.disable("x-powered-by");
app.use(express.json({ limit: "16kb" }));

const authClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  auth: {
    persistSession: false,
    autoRefreshToken: false,
    detectSessionInUrl: false
  }
});

const redis = createRedisClient({ url: REDIS_URL });
redis.on("error", (error) => {
  console.error("Error de conexión con Valkey:", error.message);
});
redis.connect().catch((error) => {
  console.error("Valkey no disponible; la API consultará Supabase sin caché:", error.message);
});

function getTable(req, res) {
  const table = req.query.table;

  if (typeof table !== "string" || !Object.hasOwn(PRODUCT_TABLES, table)) {
    res.status(400).json({ error: "La tabla solicitada no está permitida." });
    return null;
  }

  return table;
}

async function authenticate(req, res, next) {
  const authorization = req.get("authorization") || "";
  const tokenMatch = authorization.match(/^Bearer\s+(.+)$/i);

  if (!tokenMatch) {
    res.status(401).json({ error: "Inicia sesión para consultar el inventario." });
    return;
  }

  const token = tokenMatch[1];

  try {
    const { data, error } = await authClient.auth.getUser(token);
    if (error || !data?.user) {
      res.status(401).json({ error: "La sesión no es válida o expiró." });
      return;
    }

    req.accessToken = token;
    req.user = data.user;
    next();
  } catch (error) {
    console.error("No se pudo validar la sesión de Supabase:", error.message);
    res.status(503).json({ error: "No se pudo validar la sesión. Inténtalo de nuevo." });
  }
}

function getTableCacheKey(table) {
  return Buffer.from(table, "utf8").toString("hex");
}

function createUserSupabaseClient(accessToken) {
  return createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: {
      headers: { Authorization: "Bearer " + accessToken }
    },
    auth: {
      persistSession: false,
      autoRefreshToken: false,
      detectSessionInUrl: false
    }
  });
}

app.get("/api/health", async (_req, res) => {
  try {
    if (!redis.isReady) throw new Error("Valkey no está listo.");
    await redis.ping();
    res.json({ status: "ok", cache: "ready" });
  } catch {
    res.status(503).json({ status: "degraded", cache: "unavailable" });
  }
});

app.get("/api/invoices", authenticate, async (req, res) => {
  const status = req.query.status;
  if (status !== undefined && (typeof status !== "string" || !INVOICE_STATUSES.has(status))) {
    return res.status(400).json({ error: "El estado solicitado no es válido." });
  }

  try {
    const supabase = createUserSupabaseClient(req.accessToken);
    let query = supabase
      .from(INVOICE_TABLE)
      .select("idfactura, status, created_at")
      .order("created_at", { ascending: false });

    if (status) query = query.eq("status", status);

    const { data: invoices, error } = await query;
    if (error) {
      console.error("Error al consultar facturas en Supabase:", error.message);
      return res.status(502).json({ error: "No se pudieron consultar las facturas." });
    }

    res.set("Cache-Control", "no-store");
    return res.json({ invoices: invoices || [] });
  } catch (error) {
    console.error("Error inesperado al consultar facturas:", error.message);
    return res.status(500).json({ error: "Ocurrió un error al consultar las facturas." });
  }
});

app.get("/api/products", authenticate, async (req, res) => {
  const table = getTable(req, res);
  if (!table) return;

  const tableKey = getTableCacheKey(table);
  const versionKey = "inventory:v1:" + tableKey + ":" + req.user.id + ":version";
  let cacheStatus = "BYPASS";
  let version = null;

  if (redis.isReady) {
    try {
      version = (await redis.get(versionKey)) || "0";
      const cacheKey = "inventory:v1:" + tableKey + ":" + req.user.id + ":" + version;
      const cachedProducts = await redis.get(cacheKey);

      if (cachedProducts !== null) {
        res.set("X-Cache", "HIT");
        res.set("Cache-Control", "no-store");
        return res.json({ products: JSON.parse(cachedProducts), cache: "HIT" });
      }

      cacheStatus = "MISS";
    } catch (error) {
      console.error("No se pudo leer Valkey; se consultará Supabase:", error.message);
      cacheStatus = "BYPASS";
      version = null;
    }
  }

  try {
    const supabase = createUserSupabaseClient(req.accessToken);
    const { data: products, error } = await supabase
      .from(table)
      .select(PRODUCT_TABLES[table]);

    if (error) {
      console.error("Error al consultar productos en Supabase:", error.message);
      return res.status(502).json({ error: "No se pudieron consultar los productos." });
    }

    if (version !== null && redis.isReady) {
      try {
        const currentVersion = (await redis.get(versionKey)) || "0";
        if (currentVersion === version) {
          const cacheKey = "inventory:v1:" + tableKey + ":" + req.user.id + ":" + version;
          await redis.set(cacheKey, JSON.stringify(products || []), { EX: CACHE_TTL_SECONDS });
        }
      } catch (error) {
        console.error("No se pudo guardar la caché en Valkey:", error.message);
        cacheStatus = "BYPASS";
      }
    }

    res.set("X-Cache", cacheStatus);
    res.set("Cache-Control", "no-store");
    return res.json({ products: products || [], cache: cacheStatus });
  } catch (error) {
    console.error("Error inesperado al consultar productos:", error.message);
    return res.status(500).json({ error: "Ocurrió un error al consultar los productos." });
  }
});

app.post("/api/products/update", authenticate, async (req, res) => {
  const table = getTable(req, res);
  if (!table) return;

  const { id, field, value } = req.body || {};
  if (typeof id !== "string" || !id.trim()) {
    return res.status(400).json({ error: "Se requiere el id del producto." });
  }
  if (!["stock", "precio"].includes(field)) {
    return res.status(400).json({ error: "Solo se pueden actualizar stock y precio." });
  }
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0) {
    return res.status(400).json({ error: "El valor debe ser un número válido y no negativo." });
  }
  if (!redis.isReady) {
    return res.status(503).json({ error: "La caché no está disponible; no se aplicó el cambio." });
  }

  try {
    const supabase = createUserSupabaseClient(req.accessToken);
    const { data, error } = await supabase
      .from(table)
      .update({ [field]: value })
      .eq("id", id)
      .select("id")
      .maybeSingle();

    if (error) {
      console.error("Error al actualizar producto en Supabase:", error.message);
      return res.status(502).json({ error: "No se pudo actualizar el producto." });
    }
    if (!data) {
      return res.status(404).json({ error: "No se encontró el producto para actualizar." });
    }

    try {
      const versionKey = "inventory:v1:" + getTableCacheKey(table) + ":" + req.user.id + ":version";
      await redis.incr(versionKey);
    } catch (cacheError) {
      console.error("El producto se actualizó, pero no se invalidó Valkey:", cacheError.message);
      return res.status(200).json({ updated: true, cacheInvalidated: false });
    }

    return res.json({ updated: true, cacheInvalidated: true });
  } catch (error) {
    console.error("Error inesperado al actualizar producto:", error.message);
    return res.status(500).json({ error: "Ocurrió un error al actualizar el producto." });
  }
});

app.listen(PORT, "127.0.0.1", () => {
  console.log("API de inventario escuchando en 127.0.0.1:" + PORT);
});


