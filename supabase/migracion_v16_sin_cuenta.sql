-- ===== migracion_v16_sin_cuenta =====
-- v16: al fallar "Entrar", la app pregunta si el correo está invitado y aún no tiene cuenta, para guiar al socio.
create or replace function public.sin_cuenta(p_email text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.invitaciones i where lower(i.email) = lower(trim(p_email)))
     and not exists (select 1 from public.perfiles p where lower(p.email) = lower(trim(p_email)));
$$;
grant execute on function public.sin_cuenta(text) to anon, authenticated;
