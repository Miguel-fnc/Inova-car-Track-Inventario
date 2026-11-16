import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = 'https://kxvedkhwuivbefdgrrzt.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imt4dmVka2h3dWl2YmVmZGdycnp0Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTAwMTUzMzgsImV4cCI6MjEwNTU5MTMzOH0.iAn67wdxPf1qB1Q7KWIQd3c1yS5eouS8Av6nv2t3vlw';

const email = sessionStorage.getItem('userEmail');
const emailInput = document.querySelector('#userEmailDisplay');
const logoutButton = document.querySelector('#logoutBtn');
const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

if (email && emailInput) {
    userEmailDisplay.textContent = email;
}

if (logoutButton){
    logoutButton.addEventListener('click', async () => {
        sessionStorage.removeItem('userEmail');
        window.location.assign('../index.html');
    });
}