-- ===== migracion_v14_hospitales =====
-- v14: directorio de hospitales por centro y hospital por paciente (base para las constancias anuales).
create table if not exists public.hospitales (
  id uuid primary key default gen_random_uuid(),
  centro_id uuid not null references public.centros(id) on delete cascade,
  nombre text not null,
  licencia text,          -- licencia sanitaria o aviso de funcionamiento (COFEPRIS)
  telefono text,          -- conmutador y extensión
  correo_contacto text,   -- correo institucional de quien firma la carta
  activo boolean not null default true,
  creado timestamptz not null default now(),
  unique (centro_id, nombre)
);
alter table public.hospitales enable row level security;
drop policy if exists hospitales_centro on public.hospitales;
create policy hospitales_centro on public.hospitales for all to authenticated
  using (public.es_admin() or centro_id = public.mi_centro())
  with check (public.es_admin() or centro_id = public.mi_centro());
grant select, insert, update, delete on public.hospitales to authenticated;

alter table public.pacientes add column if not exists hospital_id uuid references public.hospitales(id) on delete set null;
create index if not exists pacientes_hospital_idx on public.pacientes(hospital_id);

-- Sembrar el directorio con lo que cada socio escribió al crear su cuenta ("Hospital A, Hospital B").
insert into public.hospitales (centro_id, nombre)
select c.id, trim(h)
from public.centros c, unnest(string_to_array(c.hospitales, ',')) as h
where nullif(trim(h), '') is not null
on conflict (centro_id, nombre) do nothing;

-- Si el centro tiene un solo hospital, asignarlo a sus pacientes ya capturados.
update public.pacientes p set hospital_id = u.id
from (select centro_id, min(id::text)::uuid as id from public.hospitales where activo group by centro_id having count(*) = 1) u
where p.hospital_id is null and p.centro_id = u.centro_id;

-- Mantener centros.hospitales (texto que ve Coordinación) sincronizado con el directorio.
create or replace function public.sync_centro_hospitales() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_centro uuid;
begin
  v_centro := coalesce(new.centro_id, old.centro_id);
  update public.centros c set hospitales = (
    select string_agg(h.nombre, ', ' order by h.nombre) from public.hospitales h where h.centro_id = v_centro and h.activo)
  where c.id = v_centro;
  return null;
end $$;
drop trigger if exists hospitales_sync on public.hospitales;
create trigger hospitales_sync after insert or update or delete on public.hospitales
  for each row execute function public.sync_centro_hospitales();

-- Los socios nuevos: lo que escriben en "hospitales" al crear la cuenta pasa al directorio.
create or replace function public.centro_hospitales_a_directorio() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if pg_trigger_depth() > 1 then return null; end if;
  insert into public.hospitales (centro_id, nombre)
  select new.id, trim(h) from unnest(string_to_array(new.hospitales, ',')) as h
  where nullif(trim(h), '') is not null
  on conflict (centro_id, nombre) do nothing;
  return null;
end $$;
drop trigger if exists centros_hospitales_directorio on public.centros;
create trigger centros_hospitales_directorio after insert on public.centros
  for each row execute function public.centro_hospitales_a_directorio();
