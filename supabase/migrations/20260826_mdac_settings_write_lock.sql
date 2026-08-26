-- MDAC settings must be changed through the audited RPC only.
-- The service-role Worker reads batch snapshots and never updates this table.

drop policy if exists mdac_settings_update_active on public.mdac_settings;

revoke insert, update, delete on table public.mdac_settings from anon, authenticated;
grant select on table public.mdac_settings to authenticated;

comment on table public.mdac_settings is
  'Editable MDAC business defaults. Clients select only; audited update RPC is the sole client write path. Never store service-role keys or submit flags.';
