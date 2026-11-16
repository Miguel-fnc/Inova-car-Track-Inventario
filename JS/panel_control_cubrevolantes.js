import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = 'https://kxvedkhwuivbefdgrrzt.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imt4dmVka2h3dWl2YmVmZGdycnp0Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTAwMTUzMzgsImV4cCI6MjEwNTU5MTMzOH0.iAn67wdxPf1qB1Q7KWIQd3c1yS5eouS8Av6nv2t3vlw';


const email = sessionStorage.getItem('userEmail');
const emailInput = document.querySelector('#userEmailDisplay');
const logoutButton = document.querySelector('#logoutBtn');
const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
const inventoryTableBody = document.querySelector('#inventoryTableBody');
const lineFilter = document.querySelector('#lineFilter');
const resultCount = document.querySelector('#resultCount');

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
  const { data: productos, error } = await supabase
    .from(tabla)
    .select('id, material, precio, stock');
    
  if (error) {
    console.error(`Error al consultar la tabla ${tabla}:`, error);
    console.log(`Productos: ${productos}`);
    inventoryTableBody.innerHTML = '<tr><td colspan="6" class="empty-cell">No se pudo cargar esta línea. Revisa el nombre de la tabla y sus permisos en Supabase.</td></tr>';
    resultCount.textContent = 'Error';
    return null;
  }

  return productos ?? [];
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
    const { data, error } = await supabase
      .from(tabla)
      .update({ [columna]: nuevoValor })
      .eq('id', producto.id)
      .select('id')
      .single();

    if (error) throw error;
    if (!data) throw new Error('No se encontró el producto para actualizar.');

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

  const celdaMaterial = document.createElement('td');
  celdaMaterial.textContent = producto.material;

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

  fila.append(celdaMaterial, celdaPrecio, celdaStock);
  return fila;
}

async function mostrarProductosDeLaLinea() {
  const tabla = 'CUBREVOLANTES';
  inventoryTableBody.innerHTML = '<tr><td colspan="6" class="loading-cell">Cargando productos…</td></tr>';
  resultCount.textContent = '…';

  const productos = await cargarProductos(tabla);
  
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

mostrarProductosDeLaLinea();
