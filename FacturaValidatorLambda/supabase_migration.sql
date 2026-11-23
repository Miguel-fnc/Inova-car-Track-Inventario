-- Run this in Supabase SQL Editor before deploying the validator.
ALTER TABLE public.facturas
  ADD COLUMN IF NOT EXISTS cfdi_uuid text,
  ADD COLUMN IF NOT EXISTS validation_reason text,
  ADD COLUMN IF NOT EXISTS email_notified_at timestamptz,
  ADD COLUMN IF NOT EXISTS telegram_notified_at timestamptz;

-- Ensure the estatus column accepts the validator's final states.
-- If estatus is an enum or has a CHECK constraint, add "rechazada" to it too.
