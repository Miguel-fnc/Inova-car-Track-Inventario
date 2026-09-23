import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
// 1. Sustituye estos valores con los que copiaste de Supabase Settings -> API
const SUPABASE_URL = 'https://kxvedkhwuivbefdgrrzt.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imt4dmVka2h3dWl2YmVmZGdycnp0Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTAwMTUzMzgsImV4cCI6MjEwNTU5MTMzOH0.iAn67wdxPf1qB1Q7KWIQd3c1yS5eouS8Av6nv2t3vlw';

// 2. Inicializar el cliente de Supabase
const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

// 3. Referencias del DOM
const form = document.querySelector('#loginForm');
const emailInput = document.querySelector('#email');
const passwordInput = document.querySelector('#password');
const errorBox = document.querySelector('#errorMessage');
const errorText = document.querySelector('#errorText');
const submitButton = form.querySelector('button[type="submit"]');
const submitLabel = submitButton.querySelector('span');

// 4. Manejador de Login
form.addEventListener('submit', async (event) => {
  event.preventDefault();

  const email = emailInput.value.trim();
  const password = passwordInput.value.trim();

  // Limpiar estados previos
  errorBox.classList.add('hidden');
  submitButton.disabled = true;
  submitLabel.textContent = 'Verificando...';

  try {
    // Opción A: Autenticación nativa de Supabase Auth
    const { data, error } = await supabase.auth.signInWithPassword({
      email: email,
      password: password,
    });
    
    console.log('Intentando iniciar sesión con:', email, password);

    if (error) {
      throw error;
    }

    // Si el login es exitoso
    console.log('Usuario autenticado:', data.user);
    
    // Guardar sesión y redirigir
    window.location.href = 'panel_control.html';

  } catch (error) {
    console.error('Error al iniciar sesión:', error.message);
    
    // Mostrar el mensaje de error en la alerta
    errorText.textContent = 'Correo o contraseña incorrectos.';
    errorBox.classList.remove('hidden');
  } finally {
    // Restaurar el botón
    submitButton.disabled = false;
    submitLabel.textContent = 'Ingresar al Sistema';
  }
});