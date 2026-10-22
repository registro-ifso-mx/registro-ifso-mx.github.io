-- ===== migracion_v20_seg_activar =====
-- v20: el socio puede activar/desactivar el seguimiento de SU centro (solo esa columna).
create or replace function public.centro_seguimiento(p_activo boolean)
returns void
language sql security definer set search_path = public as $$
  update public.centros set seguimiento = p_activo where id = public.mi_centro();
$$;
revoke all on function public.centro_seguimiento(boolean) from public, anon;
grant execute on function public.centro_seguimiento(boolean) to authenticated;
