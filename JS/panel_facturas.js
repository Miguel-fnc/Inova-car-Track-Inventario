import { cargarFacturasConApi } from './inventory-cache.js';

const email = sessionStorage.getItem('userEmail');
const emailDisplay = document.querySelector('#userEmailDisplay');
const logoutButton = document.querySelector('#logoutBtn');
const statusFilter = document.querySelector('#statusFilter');
const searchInput = document.querySelector('#searchInput');
const refreshButton = document.querySelector('#refreshInvoicesButton');
const tableBody = document.querySelector('#invoiceTableBody');
const resultCount = document.querySelector('#resultCount');
const sidebar = document.querySelector('#sidebar');
const menuToggle = document.querySelector('#menuToggle');
const sidebarScrim = document.querySelector('#sidebarScrim');

let facturas = [];

if (email && emailDisplay) emailDisplay.textContent = email;

logoutButton?.addEventListener('click', () => {
  sessionStorage.removeItem('userEmail');
  window.location.assign('index.html');
});

function normalizarEstado(status = '') {
  const estado = String(status)
    .trim()
    .toLowerCase()
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .replace(/[\s-]+/g, '_');
  // El bot guarda EN_PROCESO; el panel usa en_progreso para etiqueta y color.
  return estado === 'en_proceso' ? 'en_progreso' : estado;
}

function etiquetaEstado(status = '') {
  const estado = normalizarEstado(status);
  const etiquetas = {
    creada: 'Creada',
    en_progreso: 'En progreso',
    aprobada: 'Aprobada',
    rechazada: 'Rechazada'
  };
  return etiquetas[estado] || status || 'Sin estado';
}

function fechaLegible(timestamp) {
  const fecha = new Date(timestamp);
  if (Number.isNaN(fecha.getTime())) return timestamp || '—';
  return fecha.toLocaleString('es-MX', {
    dateStyle: 'medium',
    timeStyle: 'short'
  });
}

function renderizarFacturas() {
  const texto = searchInput.value.trim().toLowerCase();
  const filtradas = facturas.filter((factura) =>
    String(factura.idfactura ?? '').toLowerCase().includes(texto)
  );

  resultCount.textContent = filtradas.length;
  tableBody.replaceChildren();

  if (filtradas.length === 0) {
    tableBody.innerHTML = '<tr><td colspan="3" class="empty-cell">No hay facturas para mostrar.</td></tr>';
    return;
  }

  filtradas.forEach((factura) => {
    const fila = document.createElement('tr');
    const id = document.createElement('td');
    const estadoCell = document.createElement('td');
    const fecha = document.createElement('td');
    const badge = document.createElement('span');
    const estado = normalizarEstado(factura.status);

    id.className = 'invoice-id';
    id.textContent = factura.idfactura ?? '—';

    badge.className = 'invoice-status status-' + estado;
    badge.textContent = etiquetaEstado(factura.status);
    estadoCell.appendChild(badge);

    fecha.className = 'invoice-date';
    const timestamp = document.createElement('time');
    timestamp.dateTime = factura.created_at || '';
    timestamp.textContent = fechaLegible(factura.created_at);
    fecha.appendChild(timestamp);

    fila.append(id, estadoCell, fecha);
    tableBody.appendChild(fila);
  });
}

async function cargarFacturas() {
  tableBody.innerHTML = '<tr><td colspan="3" class="loading-cell">Cargando facturas…</td></tr>';
  resultCount.textContent = '…';
  refreshButton.disabled = true;

  try {
    facturas = await cargarFacturasConApi(statusFilter.value);
    renderizarFacturas();
  } catch (error) {
    console.error('No se pudieron cargar las facturas:', error);
    facturas = [];
    resultCount.textContent = 'Error';
    tableBody.innerHTML = '<tr><td colspan="3" class="empty-cell">No se pudieron cargar. Revisa la sesión y los permisos SELECT/RLS de la tabla facturas.</td></tr>';
  } finally {
    refreshButton.disabled = false;
  }
}

statusFilter.addEventListener('change', cargarFacturas);
searchInput.addEventListener('input', renderizarFacturas);
refreshButton.addEventListener('click', cargarFacturas);

menuToggle?.addEventListener('click', () => {
  sidebar.classList.toggle('open');
  sidebarScrim.classList.toggle('show');
});

sidebarScrim?.addEventListener('click', () => {
  sidebar.classList.remove('open');
  sidebarScrim.classList.remove('show');
});

window.lucide?.createIcons();
cargarFacturas();
window.setInterval(() => {
  if (!document.hidden) cargarFacturas();
}, 30000);
