-- ===== migracion_v18_constancias =====
-- v18: constancias anuales de participación (10 puntos de recertificación CMCG).
--  · Cada socio sube, entre el 1 de diciembre y el 15 de enero, una carta por hospital (PDF/imagen) firmada por el
--    representante legal o director, con licencia COFEPRIS, teléfono y correo del firmante y cirugías por mes.
--  · Coordinación revisa las cartas (acepta / rechaza con motivo), sortea 20 % de socios para auditoría en la última
--    semana de enero y emite la constancia con folio y QR; el socio la descarga desde su cuenta.
--  · Cualquiera puede verificar un folio en registrobariatrico.com/verificar/ (función pública verificar_constancia).

-- Datos del hospital que van en la carta (licencia, teléfono y correo ya existen desde v14).
alter table public.hospitales
  add column if not exists firmante text,        -- nombre de quien firma la carta
  add column if not exists cargo_firmante text,  -- representante legal / director general / director de la unidad
  add column if not exists domicilio text;
-- Cédula de especialidad del socio (va en la carta y en la constancia).
alter table public.perfiles add column if not exists cedula text;

-- ---------- Cartas: una por hospital y año ----------
create table if not exists public.cartas (
  id uuid primary key default gen_random_uuid(),
  centro_id uuid not null references public.centros(id) on delete cascade,
  hospital_id uuid not null references public.hospitales(id) on delete cascade,
  anio integer not null check (anio between 2025 and 2100),
  archivo text,                        -- ruta en el bucket 'cartas': centro_id/anio/hospital_id.ext
  meses integer[] not null default '{}', -- cirugías por mes según la carta (12 valores)
  total integer not null default 0,    -- total anual según la carta
  estado text not null default 'recibida' check (estado in ('recibida','aceptada','rechazada')),
  motivo text,                         -- motivo de rechazo (lo ve el socio)
  revisado_por uuid references auth.users(id) on delete set null,
  revisado timestamptz,
  subida timestamptz not null default now(),
  unique (centro_id, hospital_id, anio)
);
alter table public.cartas enable row level security;
drop policy if exists cartas_centro on public.cartas;
create policy cartas_centro on public.cartas for all to authenticated
  using (public.es_admin() or centro_id = public.mi_centro())
  with check (public.es_admin() or centro_id = public.mi_centro());
grant select, insert, update, delete on public.cartas to authenticated;
-- El socio no puede cambiar el estado ni el motivo; solo Coordinación.
create or replace function public.cartas_protege() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not public.es_admin() then
    if tg_op = 'UPDATE' and (new.estado is distinct from old.estado or new.motivo is distinct from old.motivo
                             or new.revisado_por is distinct from old.revisado_por) then
      raise exception 'Solo Coordinación revisa las cartas';
    end if;
    if tg_op = 'INSERT' then new.estado := 'recibida'; new.motivo := null; new.revisado_por := null; new.revisado := null; end if;
    if tg_op = 'UPDATE' and old.estado = 'aceptada' then raise exception 'Esta carta ya fue aceptada; pide a Coordinación si necesitas cambiarla'; end if;
    if tg_op = 'UPDATE' then new.estado := 'recibida'; new.motivo := null; new.subida := now(); end if; -- re-subir una rechazada la vuelve a poner en revisión
  else
    if tg_op = 'UPDATE' and new.estado is distinct from old.estado then new.revisado_por := auth.uid(); new.revisado := now(); end if;
  end if;
  return new;
end $$;
drop trigger if exists cartas_protege on public.cartas;
create trigger cartas_protege before insert or update on public.cartas for each row execute function public.cartas_protege();

-- ---------- Constancias: una por socio (centro) y año ----------
create table if not exists public.constancias (
  id uuid primary key default gen_random_uuid(),
  centro_id uuid not null references public.centros(id) on delete cascade,
  anio integer not null,
  folio text unique,                   -- RBM-2026-0001 (se asigna al emitir)
  estado text not null default 'pendiente' check (estado in ('pendiente','emitida','cancelada')),
  muestreado boolean not null default false,   -- salió en el sorteo del 20 %
  auditoria text,                      -- resultado: 'aprobada', 'con observaciones', etc. (texto libre de Coordinación)
  nota text,                           -- observaciones internas
  detalle jsonb,                       -- foto al emitir: socio, cédula, hospitales (nombre, sector, cirugías), total
  emitida timestamptz,
  emitida_por uuid references auth.users(id) on delete set null,
  creado timestamptz not null default now(),
  unique (centro_id, anio)
);
alter table public.constancias enable row level security;
drop policy if exists constancias_ver on public.constancias;
create policy constancias_ver on public.constancias for select to authenticated
  using (public.es_admin() or centro_id = public.mi_centro());
drop policy if exists constancias_admin on public.constancias;
create policy constancias_admin on public.constancias for all to authenticated
  using (public.es_admin()) with check (public.es_admin());
grant select, insert, update, delete on public.constancias to authenticated;

-- Textos de la constancia (quién firma). Coordinación los cambia desde la app.
insert into public.ajustes (clave, valor) values
  ('const_presidente', 'Presidente del CMCOEM'), ('const_responsable', 'Responsable del Registro Bariátrico México')
on conflict (clave) do nothing;

-- ---------- Sorteo del 20 % (última semana de enero) ----------
-- Entre los socios con al menos una carta del año que todavía no tienen constancia emitida, marca al azar el 20 %
-- (mínimo 1). Devuelve cuántos quedaron marcados en total para ese año.
create or replace function public.admin_sortear_auditoria(p_anio integer) returns integer
language plpgsql security definer set search_path = public as $$
declare n_total integer; n_meta integer; n_ya integer; r record;
begin
  if not public.es_admin() then raise exception 'Solo administradores'; end if;
  insert into public.constancias (centro_id, anio)
  select distinct centro_id, p_anio from public.cartas where anio = p_anio
  on conflict (centro_id, anio) do nothing;
  select count(*) into n_total from public.constancias where anio = p_anio and estado = 'pendiente';
  n_meta := greatest(1, ceil(n_total * 0.20));
  select count(*) into n_ya from public.constancias where anio = p_anio and muestreado;
  for r in select id from public.constancias where anio = p_anio and estado = 'pendiente' and not muestreado order by random() loop
    exit when n_ya >= n_meta;
    update public.constancias set muestreado = true where id = r.id;
    n_ya := n_ya + 1;
  end loop;
  return n_ya;
end $$;
grant execute on function public.admin_sortear_auditoria(integer) to authenticated;

-- ---------- Emisión ----------
-- Toma las cartas ACEPTADAS del socio en el año, arma el detalle (hospital, sector, cirugías verificadas) y asigna folio.
create or replace function public.admin_emitir_constancia(p_centro uuid, p_anio integer, p_auditoria text default null) returns text
language plpgsql security definer set search_path = public as $$
declare v_folio text; v_n integer; v_det jsonb; v_total integer; v_nombre text; v_cedula text; v_id uuid;
begin
  if not public.es_admin() then raise exception 'Solo administradores'; end if;
  select jsonb_agg(jsonb_build_object('hospital', h.nombre, 'clues', h.clues, 'sector', s.sector, 'cirugias', c.total) order by h.nombre),
         coalesce(sum(c.total), 0)
    into v_det, v_total
  from public.cartas c join public.hospitales h on h.id = c.hospital_id
  left join lateral (
    select case when count(*) = 0 then '—'
                when count(*) filter (where sector = 'publico') = count(*) then 'Público'
                when count(*) filter (where sector = 'privado') = count(*) then 'Privado' else 'Mixto' end as sector
    from public.pacientes p where p.hospital_id = c.hospital_id and extract(year from p.fecha) = p_anio) s on true
  where c.centro_id = p_centro and c.anio = p_anio and c.estado = 'aceptada';
  if v_det is null then raise exception 'No hay cartas aceptadas de % para %', p_centro, p_anio; end if;
  select coalesce(max(pf.nombre), ce.nombre), max(pf.cedula) into v_nombre, v_cedula
  from public.centros ce left join public.perfiles pf on pf.centro_id = ce.id and pf.rol = 'centro'
  where ce.id = p_centro group by ce.nombre;
  insert into public.constancias (centro_id, anio) values (p_centro, p_anio) on conflict (centro_id, anio) do nothing;
  select id, folio into v_id, v_folio from public.constancias where centro_id = p_centro and anio = p_anio;
  if v_folio is null then
    select count(*) + 1 into v_n from public.constancias where anio = p_anio and folio is not null;
    v_folio := 'RBM-' || p_anio || '-' || lpad(v_n::text, 4, '0');
  end if;
  update public.constancias set folio = v_folio, estado = 'emitida', emitida = now(), emitida_por = auth.uid(),
    auditoria = coalesce(p_auditoria, auditoria),
    detalle = jsonb_build_object('socio', v_nombre, 'cedula', v_cedula, 'hospitales', v_det, 'total', v_total,
      'presidente', (select valor from public.ajustes where clave = 'const_presidente'),
      'responsable', (select valor from public.ajustes where clave = 'const_responsable'))
  where id = v_id;
  return v_folio;
end $$;
grant execute on function public.admin_emitir_constancia(uuid, integer, text) to authenticated;

-- ---------- Verificación pública por folio (QR) ----------
-- Devuelve solo lo que la propia constancia ya muestra: socio, año, hospitales con cirugías verificadas, total y fecha.
create or replace function public.verificar_constancia(p_folio text) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when c.id is null then jsonb_build_object('valida', false)
    else jsonb_build_object('valida', c.estado = 'emitida', 'estado', c.estado, 'folio', c.folio, 'anio', c.anio,
      'socio', c.detalle->>'socio', 'hospitales', c.detalle->'hospitales', 'total', c.detalle->'total',
      'auditoria', c.auditoria, 'muestreado', c.muestreado, 'emitida', to_char(c.emitida at time zone 'America/Mexico_City', 'YYYY-MM-DD')) end
  from (select 1) x left join public.constancias c on c.folio = upper(trim(p_folio));
$$;
grant execute on function public.verificar_constancia(text) to anon, authenticated;

-- ---------- Archivos de las cartas (Storage) ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('cartas', 'cartas', false, 10485760, array['application/pdf','image/jpeg','image/png'])
on conflict (id) do update set public = false, file_size_limit = 10485760, allowed_mime_types = array['application/pdf','image/jpeg','image/png'];
drop policy if exists cartas_leer on storage.objects;
create policy cartas_leer on storage.objects for select to authenticated
  using (bucket_id = 'cartas' and (public.es_admin() or (storage.foldername(name))[1] = public.mi_centro()::text));
drop policy if exists cartas_subir on storage.objects;
create policy cartas_subir on storage.objects for insert to authenticated
  with check (bucket_id = 'cartas' and (public.es_admin() or (storage.foldername(name))[1] = public.mi_centro()::text));
drop policy if exists cartas_cambiar on storage.objects;
create policy cartas_cambiar on storage.objects for update to authenticated
  using (bucket_id = 'cartas' and (public.es_admin() or (storage.foldername(name))[1] = public.mi_centro()::text));
drop policy if exists cartas_borrar on storage.objects;
create policy cartas_borrar on storage.objects for delete to authenticated
  using (bucket_id = 'cartas' and (public.es_admin() or (storage.foldername(name))[1] = public.mi_centro()::text));

-- ---------- Aviso del 1 de diciembre (correo) ----------
-- A cada socio con pacientes del año: recordatorio de pedir la carta a su(s) hospital(es). Sale por el mismo
-- mecanismo que las invitaciones (pg_net → Resend), el 1 de diciembre a las 15:00 UTC (9:00 CDMX).
create or replace function public.avisar_constancias() returns integer
language plpgsql security definer set search_path = public as $$
declare k text; r record; n integer := 0; rid bigint; v_anio integer := extract(year from now())::int;
  liga constant text := 'https://registrobariatrico.com/app/';
  txt text; htm text;
begin
  select decrypted_secret into k from vault.decrypted_secrets where name = 'resend_api_key' limit 1;
  if k is null then return 0; end if;
  for r in
    select pf.email, pf.nombre, count(p.id) as n
    from public.perfiles pf join public.pacientes p on p.centro_id = pf.centro_id and extract(year from p.fecha) = v_anio
    where pf.rol = 'centro' and pf.email is not null
      and not exists (select 1 from public.correos_log l where l.email = pf.email and l.tipo = 'constancia_' || v_anio)
    group by pf.email, pf.nombre
  loop
    txt := 'Registro Bariátrico México' || chr(10) || chr(10) || 'Dr(a). ' || coalesce(r.nombre, '') || ':' || chr(10) || chr(10)
      || 'Este año registraste ' || r.n || ' paciente(s). Para descargar tu constancia de participación ' || v_anio
      || ' (10 puntos de recertificación ante el CMCG) necesitas una carta de cada hospital donde operaste, firmada por su representante legal o director.' || chr(10) || chr(10)
      || '1. Entra a ' || liga || ' → pestaña Constancia.' || chr(10)
      || '2. Descarga el formato ya llenado con tus cirugías por mes y entrégalo al hospital para firma y sello.' || chr(10)
      || '3. Sube la carta firmada antes del 15 de enero.' || chr(10) || chr(10)
      || 'Coordinación revisa las cartas en enero; la constancia queda lista para descargar desde febrero.' || chr(10) || chr(10)
      || 'Dudas: contacto@registrobariatrico.com';
    htm := '<div style=''font-family:Roboto,Arial,sans-serif;max-width:560px;margin:0 auto;color:#1b1b1f;font-size:16px;line-height:1.5''>'
      || '<h2 style=''color:#061551;margin:24px 0 8px''>Tu constancia ' || v_anio || '</h2><p>Dr(a). ' || coalesce(r.nombre, '') || ':</p>'
      || '<p>Este año registraste <b>' || r.n || '</b> paciente(s). Para descargar tu constancia de participación ' || v_anio
      || ' (10 puntos de recertificación ante el CMCG) necesitas una carta de cada hospital donde operaste, firmada por su representante legal o director.</p>'
      || '<ol style=''padding-left:22px''><li>Entra a <a href=''' || liga || '''>' || liga || '</a> → pestaña <b>Constancia</b>.</li>'
      || '<li>Descarga el formato ya llenado con tus cirugías por mes y entrégalo al hospital para firma y sello.</li>'
      || '<li>Sube la carta firmada antes del <b>15 de enero</b>.</li></ol>'
      || '<p>Coordinación revisa las cartas en enero; la constancia queda lista para descargar desde febrero.</p>'
      || '<p style=''margin:24px 0''><a href=''' || liga || ''' style=''background:#844dff;color:#fff;text-decoration:none;padding:12px 22px;border-radius:999px;font-weight:600''>Ir a mi constancia</a></p>'
      || '<p style=''color:#5a5a66;font-size:14px''>Dudas: contacto@registrobariatrico.com</p></div>';
    select net.http_post(url := 'https://api.resend.com/emails',
      headers := jsonb_build_object('Authorization', 'Bearer ' || k, 'Content-Type', 'application/json'),
      body := jsonb_build_object('from', 'Registro Bariátrico México <contacto@registrobariatrico.com>',
        'to', jsonb_build_array(r.email), 'reply_to', 'contacto@registrobariatrico.com',
        'subject', 'Registro Bariátrico México: pide la carta de tu hospital para tu constancia ' || v_anio,
        'text', txt, 'html', htm), timeout_milliseconds := 15000) into rid;
    insert into public.correos_log (email, tipo, request_id) values (r.email, 'constancia_' || v_anio, rid);
    n := n + 1;
    exit when n >= 90;
  end loop;
  return n;
end $$;
revoke all on function public.avisar_constancias() from public, anon, authenticated;
select cron.unschedule(jobid) from cron.job where jobname = 'constancias_aviso';
-- 1 de diciembre 15:00 UTC; si ese día hay más de 90 socios, el tope diario de Resend se reparte: repite el 2 y 3 de diciembre.
select cron.schedule('constancias_aviso', '0 15 1-3 12 *', $$select public.avisar_constancias()$$);
