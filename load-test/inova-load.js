// Prueba de carga realista para Inova Car con k6 (https://k6.io).
// Simula empleados que entran al sitio, abren paneles de inventario y revisan
// facturas, subiendo la cantidad de usuarios poco a poco para que el Auto
// Scaling Group de las EC2 reaccione.
//
// Variables de entorno requeridas (no pongas credenciales en este archivo):
//   SITE_URL        URL del ALB, p. ej. http://inova-car-...elb.amazonaws.com
//   API_URL         URL del API Gateway, p. ej. https://xxxx.execute-api.us-east-1.amazonaws.com
//   SUPABASE_URL    https://<ref>.supabase.co
//   SUPABASE_ANON   llave anon (pública) de Supabase
//   TEST_EMAIL      usuario de prueba del sitio
//   TEST_PASSWORD   contraseña de ese usuario de prueba
// Opcionales:
//   PEAK_USERS      usuarios simultáneos en el pico (default 50)
//
// El Auto Scaling escala por peticiones por instancia (300/min). Cada usuario
// genera unas 40 peticiones/min, así que ~15 usuarios ya superan la meta con
// 2 instancias y 50 usuarios llevan el grupo a su máximo de 4. No hace falta
// más carga: subir mucho el tráfico solo arriesga límites del lab y Supabase.

import http from 'k6/http';
import { check, sleep, group } from 'k6';

const SITE_URL = __ENV.SITE_URL;
const API_URL = __ENV.API_URL;
const PEAK = Math.min(Number(__ENV.PEAK_USERS || 50), 200);

export const options = {
  scenarios: {
    jornada_laboral: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '2m', target: Math.round(PEAK * 0.3) }, // llegan los primeros
        { duration: '3m', target: PEAK },                   // se llena la oficina
        { duration: '10m', target: PEAK },                  // hora pico sostenida
        { duration: '2m', target: Math.round(PEAK * 0.2) }, // baja la demanda
        { duration: '1m', target: 0 },
      ],
      gracefulRampDown: '30s',
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.05'],
    'http_req_duration{tipo:api}': ['p(95)<3000'],
  },
};

const TABLAS = [
  'ACEITE CASTROL EDGE', 'ACEITE CASTROL GTX MINERAL', 'ACEITE CASTROL GTX SINTETICO',
  'ACEITE MOBIL BLEND', 'ACEITE MOBIL PEGASSO', 'ACEITE MOBIL NACIONAL', 'ACEITE MOBIL 1',
  'ACEITE MOBIL DELVAC', 'LIMPIAPARABRISAS BRONX', 'LIMPIAPARABRISAS RACING',
  'BUJIAS', 'CUBREVOLANTES', 'FILTROS', 'TAPETES',
];
const PANELES = [
  'panel_control_castrol.html', 'panel_control_mobil.html', 'panel_control_bujias.html',
  'panel_control_filtros.html', 'panel_control_tapetes.html', 'panel_control_cubrevolantes.html',
  'panel_control_limpiparabrisas.html', 'panel_control_rooshfran.html',
];
const ESTADOS = ['', 'creada', 'en_progreso', 'aprobada', 'rechazada'];

const pick = (list) => list[Math.floor(Math.random() * list.length)];

// Inicia sesión una vez y comparte el token (dura 1 hora) entre los usuarios
// virtuales, igual que el login del sitio con supabase-js.
export function setup() {
  for (const name of ['SITE_URL', 'API_URL', 'SUPABASE_URL', 'SUPABASE_ANON', 'TEST_EMAIL', 'TEST_PASSWORD']) {
    if (!__ENV[name]) throw new Error(`Falta la variable de entorno ${name}`);
  }
  const res = http.post(
    `${__ENV.SUPABASE_URL}/auth/v1/token?grant_type=password`,
    // Same trimming as JS/Login.js so the script logs in exactly like the site.
    JSON.stringify({ email: __ENV.TEST_EMAIL.trim(), password: __ENV.TEST_PASSWORD.trim() }),
    { headers: { apikey: __ENV.SUPABASE_ANON, 'Content-Type': 'application/json' } },
  );
  if (res.status !== 200) {
    let motivo = '';
    try {
      const body = res.json();
      motivo = body.error_code || body.error || '';
      motivo += body.msg || body.error_description ? ` - ${body.msg || body.error_description}` : '';
    } catch (_) { /* respuesta sin JSON */ }
    throw new Error(`Login falló (HTTP ${res.status}): ${motivo}`);
  }
  return { token: res.json('access_token') };
}

export default function (data) {
  const auth = { headers: { Authorization: `Bearer ${data.token}` }, tags: { tipo: 'api' } };

  group('abrir panel de inventario', () => {
    const panel = pick(PANELES);
    const page = http.batch([
      ['GET', `${SITE_URL}/${panel}`, null, { tags: { tipo: 'sitio' } }],
      ['GET', `${SITE_URL}/CSS/panel.css`, null, { tags: { tipo: 'sitio' } }],
      ['GET', `${SITE_URL}/JS/inventory-cache.js`, null, { tags: { tipo: 'sitio' } }],
    ]);
    check(page[0], { 'panel 200': (r) => r.status === 200 });

    // Un panel carga entre 1 y 3 líneas de producto.
    const lineas = 1 + Math.floor(Math.random() * 3);
    for (let i = 0; i < lineas; i++) {
      const r = http.get(`${API_URL}/api/products?table=${encodeURIComponent(pick(TABLAS))}`, auth);
      check(r, { 'productos 200': (x) => x.status === 200 });
      sleep(1 + Math.random() * 2); // el usuario revisa la tabla
    }
  });

  // 40 % de los usuarios revisa también el panel de facturas.
  if (Math.random() < 0.4) {
    group('revisar facturas', () => {
      http.get(`${SITE_URL}/panel_facturas.html`, { tags: { tipo: 'sitio' } });
      const estado = pick(ESTADOS);
      const qs = estado ? `?status=${estado}` : '';
      const r = http.get(`${API_URL}/api/invoices${qs}`, auth);
      check(r, { 'facturas 200': (x) => x.status === 200 });
    });
  }

  sleep(2 + Math.random() * 4); // pausa antes de la siguiente acción
}
