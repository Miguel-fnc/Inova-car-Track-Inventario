import { cargarProductosConCache, actualizarProductoConApi } from './inventory-cache.js';


const email = sessionStorage.getItem('userEmail');
const emailInput = document.querySelector('#userEmailDisplay');
const logoutButton = document.querySelector('#logoutBtn');
const inventoryTableBody = document.querySelector('#inventoryTableBody');
const resultCount = document.querySelector('#resultCount');
const searchInput = document.querySelector('#searchInput');
const updateButton = document.querySelector('#submitButton');

let productosCargados = [];
let tablaActual = 'TAPETES';

if (email && emailInput) {
    userEmailDisplay.textContent = email;
}

if (logoutButton){
    logoutButton.addEventListener('click', async () => {
        sessionStorage.removeItem('userEmail');
        window.location.assign('../index.html');
    });
}

async function cargarProductos(tabla) {
  try {
    return await cargarProductosConCache(tabla);
  } catch (error) {
    console.error("Error al consultar tabla " + tabla + " a través de la API:", error);
    inventoryTableBody.innerHTML = '<tr><td colspan="6" class="empty-cell">No se pudo cargar esta línea. Revisa la sesión y los permisos en Supabase.</td></tr>';
    resultCount.textContent = 'Error';
    return null;
  }
}
async function guardarCambio(input, producto, columna, tabla) {
  const valorAnterior = producto[columna];
  const nuevoValor = input.valueAsNumber;

  if (input.value === '' || !Number.isFinite(nuevoValor)) {
    input.value = valorAnterior ?? '';
    return;
  }

  input.disabled = true;
  input.title = 'Guardando…';

  try {
    await actualizarProductoConApi(tabla, producto.id, columna, nuevoValor);
    producto[columna] = nuevoValor;
    input.title = 'Guardado';
    input.style.borderColor = '#3fbaa9';
  } catch (error) {
    console.error(`No se pudo guardar ${columna}:`, error);
    input.value = valorAnterior ?? '';
    input.title = 'No se guardó el cambio';
    input.style.borderColor = '#dc2626';
    window.alert('No se guardó el cambio. Revisa tu conexión y los permisos de actualización en Supabase.');
  } finally {
    input.disabled = false;
  }
}

function crearFila(producto, tabla) {
  const fila = document.createElement('tr');

  const celdaPresentacion = document.createElement('td');
  celdaPresentacion.textContent = producto.presentacion;

  const celdaColor = document.createElement('td');
  celdaColor.textContent = producto.color;

  const celdaPiezas = document.createElement('td');
  celdaPiezas.textContent = producto.piezas;

  const celdaPrecio = document.createElement("td")
  const inputPrecio = document.createElement("input");
  inputPrecio.classList.add("precio-input");
  inputPrecio.type = "number";
  inputPrecio.value = producto.precio;
  inputPrecio.step = "0.01";
  inputPrecio.addEventListener('change', () => guardarCambio(inputPrecio, producto, 'precio', tabla));
  celdaPrecio.appendChild(inputPrecio);

  const celdaStock = document.createElement("td");
  const inputStock = document.createElement("input");
  inputStock.classList.add("stock-input");
  inputStock.type = "number";
  inputStock.value = producto.stock;
  inputStock.step = "1";
  inputStock.addEventListener('change', () => guardarCambio(inputStock, producto, 'stock', tabla));
  celdaStock.appendChild(inputStock);

  fila.append(celdaPresentacion, celdaColor, celdaPiezas, celdaStock, celdaPrecio);
  return fila;
}

async function mostrarProductosDeLaLinea() {
  const tabla = 'TAPETES';
  inventoryTableBody.innerHTML = '<tr><td colspan="6" class="loading-cell">Cargando productos…</td></tr>';
  resultCount.textContent = '…';

  const productos = await cargarProductos(tabla);
  productosCargados = productos;
  tablaActual = tabla;
  
  if (!productos) return;

  inventoryTableBody.replaceChildren();
  resultCount.textContent = productos.length;

  if (productos.length === 0) {
    inventoryTableBody.innerHTML = '<tr><td colspan="6" class="empty-cell">No hay productos en esta línea.</td></tr>';
    return;
  }

  productos.forEach((producto) => {
    inventoryTableBody.appendChild(crearFila(producto, tabla));
  });
}

function buscarProductos() {
  const texto = searchInput.value.trim().toLowerCase();

  const productosFiltrados = productosCargados.filter((producto) => {
    return (
      String(producto.presentacion ?? '').toLowerCase().includes(texto) ||
      String(producto.color ?? '').toLowerCase().includes(texto) ||
      String(producto.piezas ?? '').toLowerCase().includes(texto)
    );
  });

  inventoryTableBody.replaceChildren();

  productosFiltrados.forEach((producto) => {
    inventoryTableBody.appendChild(crearFila(producto, tablaActual));
  });

  resultCount.textContent = productosFiltrados.length;
}

updateButton.addEventListener('click', async () => {
  window.location.reload();
});

updateButton.addEventListener('click', async () => {
  window.location.reload();
});

searchInput.addEventListener('input', buscarProductos);
mostrarProductosDeLaLinea();
