-- ===== migracion_v19_seguimiento =====
-- v19: seguimiento OPCIONAL del paciente a 1, 3, 6, 12, 18 y 24 meses, en su propia pestaña.
--  · Cada socio lo activa si quiere (centros.seguimiento). La captura del registro no cambia.
--  · Por control: fecha, peso (→ IMC, %PPT, %PEP), % grasa y masa muscular (opcionales, bioimpedancia),
--    estado de las comorbilidades que tenía al inicio, complicación/reoperación tardía, GLP-1 actual.
--  · Recordatorio: UNA notificación al mes en el celular (app instalada), sin datos del paciente,
--    enviada por el workflow "Recordatorios de seguimiento" (repo respaldos) con Web Push. Cero correos.
alter table public.centros add column if not exists seguimiento boolean not null default false;
alter table public.pacientes add column if not exists seg_baja boolean not null default false; -- "no dar seguimiento a este paciente"

create table if not exists public.seguimientos (
  id uuid primary key default gen_random_uuid(),
  paciente_id uuid not null references public.pacientes(id) on delete cascade,
  centro_id uuid not null references public.centros(id) on delete cascade,
  meses smallint not null check (meses in (1,3,6,12,18,24)),
  fecha date not null,
  perdido boolean not null default false,          -- no acudió / sin contacto
  peso numeric(5,1) check (peso is null or peso between 20 and 400),
  imc numeric(5,1) check (imc is null or imc between 10 and 120),
  grasa_pct numeric(4,1) check (grasa_pct is null or grasa_pct between 1 and 80),
  masa_muscular numeric(5,1) check (masa_muscular is null or masa_muscular between 5 and 150),
  comorb jsonb not null default '{}'::jsonb,       -- {"dm2":"remision","has":"mejoria",...} remision|mejoria|igual|peor
  complicacion boolean not null default false,
  complicacion_tipo text,
  reoperacion boolean not null default false,
  glp1 boolean,
  notas text,
  creado timestamptz not null default now(),
  creado_por uuid references auth.users(id) on delete set null,
  unique (paciente_id, meses)
);
create index if not exists seguimientos_centro_idx on public.seguimientos (centro_id, meses);
alter table public.seguimientos enable row level security;
drop policy if exists seguimientos_centro on public.seguimientos;
create policy seguimientos_centro on public.seguimientos for all to authenticated
  using (public.es_admin() or centro_id = public.mi_centro())
  with check (public.es_admin() or centro_id = public.mi_centro());
grant select, insert, update, delete on public.seguimientos to authenticated;

-- Resumen nacional anónimo del seguimiento (misma lógica que pacientes_anonimos): sin centro, folio ni fecha.
create or replace function public.seguimientos_anonimos()
returns table (meses smallint, perdido boolean, ppt numeric, pep numeric, imc numeric, grasa_pct numeric,
               comorb jsonb, complicacion boolean, reoperacion boolean, glp1 boolean, proc text, tipo text)
language sql stable security definer set search_path = public as $$
  select s.meses, s.perdido,
         case when s.peso is not null and p.peso is not null and p.peso > 0 then round((p.peso - s.peso) / p.peso * 100, 1) end as ppt,
         case when s.peso is not null and p.peso is not null and p.talla is not null and p.peso > 25 * (p.talla/100)^2
              then round((p.peso - s.peso) / (p.peso - 25 * (p.talla/100)^2) * 100, 1) end as pep,
         s.imc, s.grasa_pct, s.comorb, s.complicacion, s.reoperacion, s.glp1, p.proc, p.tipo
  from public.seguimientos s join public.pacientes p on p.id = s.paciente_id
  where auth.uid() is not null
  order by random();
$$;
grant execute on function public.seguimientos_anonimos() to authenticated;

-- ---------- Notificaciones push (una al mes) ----------
create table if not exists public.push_suscripciones (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  dispositivo text,
  creado timestamptz not null default now(),
  ultimo_envio timestamptz,
  fallos smallint not null default 0
);
alter table public.push_suscripciones enable row level security;
drop policy if exists push_propias on public.push_suscripciones;
create policy push_propias on public.push_suscripciones for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
grant select, insert, update, delete on public.push_suscripciones to authenticated;

-- Controles que tocan este mes (ventana ±1 mes alrededor de fecha de cirugía + meses), por usuario.
-- La usa el workflow de recordatorios con la service key (no se expone a los usuarios).
create or replace function public.controles_pendientes()
returns table (user_id uuid, pendientes integer)
language sql stable security definer set search_path = public as $$
  with hitos as (select unnest(array[1,3,6,12,18,24]) as m),
  pend as (
    select p.centro_id, count(*) as n
    from public.pacientes p join public.centros c on c.id = p.centro_id and c.seguimiento
    cross join hitos h
    where not p.seg_baja
      and current_date between (p.fecha + (h.m - 1) * interval '1 month')::date and (p.fecha + (h.m + 1) * interval '1 month')::date
      and not exists (select 1 from public.seguimientos s where s.paciente_id = p.id and s.meses = h.m)
    group by p.centro_id)
  select pf.user_id, pend.n::integer
  from pend join public.perfiles pf on pf.centro_id = pend.centro_id and pf.rol = 'centro';
$$;
revoke all on function public.controles_pendientes() from public, anon, authenticated;
