import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = 'https://kxvedkhwuivbefdgrrzt.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imt4dmVka2h3dWl2YmVmZGdycnp0Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTAwMTUzMzgsImV4cCI6MjEwNTU5MTMzOH0.iAn67wdxPf1qB1Q7KWIQd3c1yS5eouS8Av6nv2t3vlw';
const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

const form = document.querySelector('#loginForm');
const emailInput = document.querySelector('#email');
const passwordInput = document.querySelector('#password');
const errorBox = document.querySelector('#errorMessage');
const errorText = document.querySelector('#errorText');
const submitButton = form?.querySelector('button[type="submit"]');
const submitLabel = submitButton?.querySelector('.button-label');

if (form && emailInput && passwordInput && errorBox && errorText && submitButton && submitLabel) {
  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    errorBox.hidden = true;
    errorBox.classList.add('hidden');
    submitButton.disabled = true;
    submitLabel.textContent = 'Verificando…';

    try {
      const { data, error } = await supabase.auth.signInWithPassword({
        email: emailInput.value.trim(),
        password: passwordInput.value.trim(),
      });

      if (error) throw error;
      if (!data.session || !data.user) throw new Error('No se pudo iniciar la sesión.');

      sessionStorage.setItem('userEmail', data.user.email ?? emailInput.value.trim());
      window.location.assign('panel_control_mobil.html');
    } catch (error) {
      console.error('Error al iniciar sesión:', error);
      errorText.textContent = error?.message === 'Failed to fetch'
        ? 'No se pudo conectar. Revisa tu conexión e inténtalo de nuevo.'
        : 'Correo o contraseña incorrectos. Verifica tus datos e inténtalo de nuevo.';
      errorBox.hidden = false;
      errorBox.classList.remove('hidden');
      passwordInput.focus();
    } finally {
      submitButton.disabled = false;
      submitLabel.textContent = 'Entrar al sistema';
    }
  });
}
