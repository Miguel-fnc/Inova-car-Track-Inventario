import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { API_BASE_URL } from "./api-config.js";

const SUPABASE_URL = "https://kxvedkhwuivbefdgrrzt.supabase.co";
const SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imt4dmVka2h3dWl2YmVmZGdycnp0Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTAwMTUzMzgsImV4cCI6MjEwNTU5MTMzOH0.iAn67wdxPf1qB1Q7KWIQd3c1yS5eouS8Av6nv2t3vlw";

export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

async function getAccessToken() {
  const { data, error } = await supabase.auth.getSession();
  if (error) throw error;
  if (!data.session?.access_token) {
    throw new Error("No hay una sesión activa. Inicia sesión de nuevo.");
  }
  return data.session.access_token;
}

export async function cargarProductosConCache(table) {
  const token = await getAccessToken();
  const response = await fetch(API_BASE_URL + "/api/products?table=" + encodeURIComponent(table), {
    headers: { Authorization: "Bearer " + token },
    cache: "no-store"
  });

  const result = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(result.error || "No se pudieron cargar los productos.");
  }

  console.info("Caché de productos " + table + ": " + result.cache);
  return result.products || [];
}

export async function actualizarProductoConApi(table, id, field, value) {
  const token = await getAccessToken();
  const response = await fetch(API_BASE_URL + "/api/products/update?table=" + encodeURIComponent(table), {
    method: "POST",
    headers: {
      Authorization: "Bearer " + token,
      "Content-Type": "application/json"
    },
    body: JSON.stringify({ id, field, value }),
    cache: "no-store"
  });

  const result = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(result.error || "No se pudo actualizar el producto.");
  }

  if (!result.cacheInvalidated) {
    console.warn("El producto se guardó; la caché puede tardar hasta un minuto en reflejar el cambio.");
  }

  return result;
}

export async function cargarFacturasConApi(status = "") {
  const token = await getAccessToken();
  const query = status ? "?status=" + encodeURIComponent(status) : "";
  const response = await fetch(API_BASE_URL + "/api/invoices" + query, {
    headers: { Authorization: "Bearer " + token },
    cache: "no-store"
  });

  const result = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(result.error || "No se pudieron cargar las facturas.");
  }

  return result.invoices || [];
}

