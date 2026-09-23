// Solo devuelve la URL del proyecto y la clave anon/public de Supabase.
// Nunca coloques aquí ni expongas la service_role key.
module.exports = (req, res) => {
  if (req.method !== 'GET') {
    res.setHeader('Allow', 'GET');
    return res.status(405).json({ error: 'Método no permitido' });
  }

  const url = process.env.SUPABASE_URL;
  const anonKey = process.env.SUPABASE_ANON_KEY;

  if (!url || !anonKey) {
    return res.status(500).json({ error: 'Falta configurar Supabase en las variables de entorno de Vercel.' });
  }

  return res.status(200).json({ url, anonKey });
};
