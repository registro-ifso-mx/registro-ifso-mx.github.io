-- ===== migracion_v15_clues =====
-- v15: catálogo nacional CLUES (Secretaría de Salud, DGIS) para elegir el hospital de una lista oficial,
-- y vínculo hospitales.clues. Datos: cargados por el workflow "Cargar catálogo CLUES" (repo respaldos).
create extension if not exists pg_trgm;
create table if not exists public.clues (
  clues text primary key,
  nombre text not null,
  nombre_comercial text,
  institucion text,
  tipo text not null check (tipo in ('hospital','consulta')),
  tipologia text,
  entidad text,
  municipio text,
  cp text,
  telefono text,
  rfc text,
  busqueda text not null,
  actualizado timestamptz not null default now()
);
create index if not exists clues_busqueda_trgm on public.clues using gin (busqueda gin_trgm_ops);
alter table public.clues enable row level security;
drop policy if exists clues_leer on public.clues;
create policy clues_leer on public.clues for select to authenticated using (true);
grant select on public.clues to authenticated;

alter table public.hospitales
  add column if not exists clues text references public.clues(clues),
  add column if not exists validacion text not null default 'pendiente' check (validacion in ('pendiente','validado','rechazado')),
  add column if not exists municipio text,
  add column if not exists entidad text;
create index if not exists hospitales_clues_idx on public.hospitales(clues);

-- Búsqueda: hasta 15 coincidencias por nombre, nombre comercial, municipio o entidad (sin acentos).
create or replace function public.buscar_clues(q text)
returns table (clues text, nombre text, nombre_comercial text, institucion text, tipo text, tipologia text, entidad text, municipio text, telefono text)
language sql stable security definer set search_path = public as $$
  with t as (select lower(regexp_replace(translate(coalesce(q,''), 'áéíóúüÁÉÍÓÚÜñÑ', 'aeiouuAEIOUUnN'), '[^a-zA-Z0-9 ]+', ' ', 'g')) as s)
  select c.clues, c.nombre, c.nombre_comercial, c.institucion, c.tipo, c.tipologia, c.entidad, c.municipio, c.telefono
  from public.clues c, t
  where auth.uid() is not null and length(t.s) >= 3
    and (select bool_and(c.busqueda like '%' || w || '%') from unnest(string_to_array(trim(t.s), ' ')) w where w <> '')
  order by (c.tipo = 'hospital') desc, similarity(c.busqueda, t.s) desc, c.nombre
  limit 15;
$$;
grant execute on function public.buscar_clues(text) to authenticated;
