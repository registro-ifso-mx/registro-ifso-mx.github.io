-- =====================================================================
--  REGISTRO IFSO MÉXICO · esquema de base de datos (Supabase / Postgres)
--  Pegar completo en: Supabase → SQL Editor → New query → Run
--  Es seguro correrlo más de una vez.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------- Tablas ----------
create table if not exists public.centros (
  id          uuid primary key default gen_random_uuid(),
  nombre      text not null unique,
  ciudad      text,
  estado      text,
  codigo      text not null unique default upper(substr(encode(gen_random_bytes(6),'hex'),1,6)),
  activo      boolean not null default true,
  creado      timestamptz not null default now()
);

create table if not exists public.perfiles (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  email       text,
  nombre      text,
  rol         text not null default 'centro' check (rol in ('admin','centro')),
  centro_id   uuid references public.centros(id) on delete set null,
  creado      timestamptz not null default now()
);

create table if not exists public.pacientes (
  id          uuid primary key default gen_random_uuid(),
  centro_id   uuid not null references public.centros(id) on delete cascade,
  creado_por  uuid references auth.users(id) on delete set null,
  fecha       date not null,
  folio       text,
  sexo        text not null check (sexo in ('M','H')),
  edad        integer not null check (edad between 10 and 100),
  imc         numeric(5,1) not null check (imc between 15 and 120),
  dm2         boolean not null default false,
  has         boolean not null default false,
  dislip      boolean not null default false,
  tipo        text not null check (tipo in ('primaria','revisional')),
  proc        text not null check (proc in ('manga','oagb','bypass','sadis','oatb','biparticion','manga_endo','allurion','balon','otra')),
  abordaje    text not null check (abordaje in ('laparoscopica','robotica','abierta','endoscopica')),
  estancia    integer not null check (estancia between 0 and 365),
  reop        boolean not null default false,
  muerte      boolean not null default false,
  notas       text,
  creado      timestamptz not null default now(),
  actualizado timestamptz not null default now()
);
create index if not exists pacientes_centro_fecha on public.pacientes (centro_id, fecha desc);

-- ---------- Funciones auxiliares (evitan recursión en las políticas) ----------
create or replace function public.es_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select rol = 'admin' from public.perfiles where user_id = auth.uid()), false);
$$;

create or replace function public.mi_centro() returns uuid
language sql stable security definer set search_path = public as $$
  select centro_id from public.perfiles where user_id = auth.uid();
$$;

-- Perfil automático al registrarse. El PRIMER usuario registrado es administrador.
create or replace function public.crear_perfil() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.perfiles (user_id, email, nombre, rol)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'nombre', split_part(new.email,'@',1)),
    case when (select count(*) from public.perfiles) = 0 then 'admin' else 'centro' end
  )
  on conflict (user_id) do nothing;
  return new;
end $$;
drop trigger if exists crear_perfil on auth.users;
create trigger crear_perfil after insert on auth.users
  for each row execute function public.crear_perfil();

-- Un cirujano se une a su centro con el código que le dio el administrador.
create or replace function public.unirse_a_centro(p_codigo text) returns public.centros
language plpgsql security definer set search_path = public as $$
declare c public.centros;
begin
  select * into c from public.centros where codigo = upper(trim(p_codigo)) and activo;
  if c.id is null then raise exception 'Código no válido'; end if;
  update public.perfiles set centro_id = c.id where user_id = auth.uid();
  return c;
end $$;

create or replace function public.actualizar_nombre(p_nombre text) returns void
language sql security definer set search_path = public as $$
  update public.perfiles set nombre = trim(p_nombre) where user_id = auth.uid();
$$;

-- Administrador: reasignar rol o centro de un usuario.
create or replace function public.admin_actualizar_perfil(p_user uuid, p_rol text, p_centro uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.es_admin() then raise exception 'Solo administradores'; end if;
  update public.perfiles set rol = p_rol, centro_id = p_centro where user_id = p_user;
end $$;

-- Resumen nacional: cualquier usuario autenticado recibe las filas SIN centro, fecha ni folio
-- (no se puede saber de qué centro es cada una). Con eso la app calcula el resumen de México.
create or replace function public.pacientes_anonimos(p_anio integer default null)
returns table (sexo text, edad integer, imc numeric, dm2 boolean, has boolean, dislip boolean,
               tipo text, proc text, abordaje text, estancia integer, reop boolean, muerte boolean)
language sql stable security definer set search_path = public as $$
  select sexo, edad, imc, dm2, has, dislip, tipo, proc, abordaje, estancia, reop, muerte
  from public.pacientes
  where auth.uid() is not null and (p_anio is null or extract(year from fecha) = p_anio)
  order by random();
$$;

create or replace function public.tocar_actualizado() returns trigger language plpgsql as $$
begin new.actualizado = now(); return new; end $$;
drop trigger if exists pacientes_actualizado on public.pacientes;
create trigger pacientes_actualizado before update on public.pacientes
  for each row execute function public.tocar_actualizado();

-- ---------- Seguridad por fila (RLS) ----------
alter table public.centros   enable row level security;
alter table public.perfiles  enable row level security;
alter table public.pacientes enable row level security;

drop policy if exists centros_ver on public.centros;
create policy centros_ver on public.centros for select to authenticated
  using (public.es_admin() or id = public.mi_centro());
drop policy if exists centros_admin on public.centros;
create policy centros_admin on public.centros for all to authenticated
  using (public.es_admin()) with check (public.es_admin());

drop policy if exists perfiles_ver on public.perfiles;
create policy perfiles_ver on public.perfiles for select to authenticated
  using (public.es_admin() or user_id = auth.uid());

drop policy if exists pacientes_centro on public.pacientes;
create policy pacientes_centro on public.pacientes for all to authenticated
  using (public.es_admin() or centro_id = public.mi_centro())
  with check (public.es_admin() or centro_id = public.mi_centro());

grant usage on schema public to authenticated;
grant select, insert, update, delete on public.centros, public.perfiles, public.pacientes to authenticated;
grant execute on function public.es_admin(), public.mi_centro(), public.unirse_a_centro(text),
  public.actualizar_nombre(text), public.admin_actualizar_perfil(uuid, text, uuid),
  public.pacientes_anonimos(integer) to authenticated;
-- Gestión de centros por el coordinador: renombrar, activar/desactivar, fusionar, borrar.
create or replace function public.admin_fusionar_centros(p_origen uuid, p_destino uuid) returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if not public.es_admin() then raise exception 'Solo administradores'; end if;
  if p_origen = p_destino then raise exception 'El origen y el destino son el mismo centro'; end if;
  if not exists (select 1 from public.centros where id = p_destino) then raise exception 'Centro destino no existe'; end if;
  update public.pacientes set centro_id = p_destino where centro_id = p_origen;
  get diagnostics n = row_count;
  update public.perfiles set centro_id = p_destino where centro_id = p_origen;
  delete from public.centros where id = p_origen;
  return n;
end $$;

create or replace function public.admin_borrar_centro(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.es_admin() then raise exception 'Solo administradores'; end if;
  if exists (select 1 from public.pacientes where centro_id = p_id) then raise exception 'El centro tiene pacientes; fusiónalo o desactívalo'; end if;
  update public.perfiles set centro_id = null where centro_id = p_id;
  delete from public.centros where id = p_id;
end $$;

grant execute on function public.admin_fusionar_centros(uuid, uuid), public.admin_borrar_centro(uuid) to authenticated;
-- =====================================================================
--  Migración v2: campos nuevos (origen, sector, GLP-1) + módulo de residentes
--  Es seguro correrla más de una vez.
-- =====================================================================

-- ---------- Registro principal: campos nuevos ----------
alter table public.pacientes add column if not exists origen text not null default 'nacional';
alter table public.pacientes add column if not exists sector text not null default 'privado';
alter table public.pacientes add column if not exists glp1   boolean not null default false;
alter table public.pacientes drop constraint if exists pacientes_origen_check;
alter table public.pacientes add constraint pacientes_origen_check check (origen in ('nacional','internacional'));
alter table public.pacientes drop constraint if exists pacientes_sector_check;
alter table public.pacientes add constraint pacientes_sector_check check (sector in ('publico','privado'));

-- El resumen nacional anónimo también devuelve los campos nuevos.
drop function if exists public.pacientes_anonimos(integer);
create or replace function public.pacientes_anonimos(p_anio integer default null)
returns table (sexo text, edad integer, imc numeric, dm2 boolean, has boolean, dislip boolean,
               tipo text, proc text, abordaje text, estancia integer, reop boolean, muerte boolean,
               origen text, sector text, glp1 boolean)
language sql stable security definer set search_path = public as $$
  select sexo, edad, imc, dm2, has, dislip, tipo, proc, abordaje, estancia, reop, muerte, origen, sector, glp1
  from public.pacientes
  where auth.uid() is not null and (p_anio is null or extract(year from fecha) = p_anio)
  order by random();
$$;
grant execute on function public.pacientes_anonimos(integer) to authenticated;

-- ---------- Residentes ----------
-- Un residente es un usuario con rol 'residente'. Lleva su propia bitácora (no cuenta en el reporte IFSO).
alter table public.perfiles drop constraint if exists perfiles_rol_check;
alter table public.perfiles add constraint perfiles_rol_check check (rol in ('admin','centro','residente'));
alter table public.perfiles add column if not exists sede text;      -- hospital / programa de residencia
alter table public.perfiles add column if not exists anio_res text;  -- año de residencia (R1, R2, fellow…)

-- Al registrarse desde la página de residentes, la app manda rol='residente' en los metadatos.
create or replace function public.crear_perfil() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.perfiles (user_id, email, nombre, rol, sede, anio_res)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'nombre', split_part(new.email,'@',1)),
    case when (select count(*) from public.perfiles) = 0 then 'admin'
         when new.raw_user_meta_data->>'rol' = 'residente' then 'residente'
         else 'centro' end,
    new.raw_user_meta_data->>'sede',
    new.raw_user_meta_data->>'anio_res'
  )
  on conflict (user_id) do nothing;
  return new;
end $$;

create table if not exists public.residentes_casos (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  fecha         date not null,
  centro_nombre text not null,
  sector        text not null check (sector in ('publico','privado')),
  participacion text not null check (participacion in ('cirujano','primer_ayudante','segundo_ayudante')),
  folio         text,
  sexo          text not null check (sexo in ('M','H')),
  edad          integer not null check (edad between 10 and 100),
  imc           numeric(5,1) not null check (imc between 15 and 120),
  origen        text not null default 'nacional' check (origen in ('nacional','internacional')),
  glp1          boolean not null default false,
  dm2           boolean not null default false,
  has           boolean not null default false,
  dislip        boolean not null default false,
  tipo          text not null check (tipo in ('primaria','revisional')),
  proc          text not null check (proc in ('manga','oagb','bypass','sadis','oatb','biparticion','manga_endo','allurion','balon','otra')),
  abordaje      text not null check (abordaje in ('laparoscopica','robotica','abierta','endoscopica')),
  estancia      integer not null check (estancia between 0 and 365),
  reop          boolean not null default false,
  muerte        boolean not null default false,
  notas         text,
  creado        timestamptz not null default now(),
  actualizado   timestamptz not null default now()
);
create index if not exists residentes_casos_user_fecha on public.residentes_casos (user_id, fecha desc);
drop trigger if exists residentes_casos_actualizado on public.residentes_casos;
create trigger residentes_casos_actualizado before update on public.residentes_casos
  for each row execute function public.tocar_actualizado();

alter table public.residentes_casos enable row level security;
drop policy if exists residentes_propios on public.residentes_casos;
create policy residentes_propios on public.residentes_casos for all to authenticated
  using (user_id = auth.uid() or public.es_admin())
  with check (user_id = auth.uid());
grant select, insert, update, delete on public.residentes_casos to authenticated;

-- El residente puede actualizar su sede/año.
create or replace function public.actualizar_residente(p_sede text, p_anio text) returns void
language sql security definer set search_path = public as $$
  update public.perfiles set sede = nullif(trim(p_sede),''), anio_res = nullif(trim(p_anio),'') where user_id = auth.uid();
$$;
grant execute on function public.actualizar_residente(text, text) to authenticated;
-- =====================================================================
--  Migración v3: registro cerrado por invitación.
--  Solo puede crear cuenta un correo que el coordinador haya invitado.
--  Al registrarse, el usuario queda en el centro (o como residente) que dice su invitación.
-- =====================================================================

create table if not exists public.invitaciones (
  email       text primary key,
  rol         text not null default 'centro' check (rol in ('admin','centro','residente')),
  centro_id   uuid references public.centros(id) on delete set null,
  nota        text,
  invitado_por uuid references auth.users(id) on delete set null,
  creado      timestamptz not null default now(),
  usado       timestamptz
);
alter table public.invitaciones enable row level security;
drop policy if exists invitaciones_admin on public.invitaciones;
create policy invitaciones_admin on public.invitaciones for all to authenticated
  using (public.es_admin()) with check (public.es_admin());
grant select, insert, update, delete on public.invitaciones to authenticated;

-- Interruptor: si está en 'true', solo se registran correos invitados.
create table if not exists public.ajustes (clave text primary key, valor text);
insert into public.ajustes (clave, valor) values ('registro_cerrado','true') on conflict (clave) do nothing;
alter table public.ajustes enable row level security;
drop policy if exists ajustes_ver on public.ajustes;
create policy ajustes_ver on public.ajustes for select to authenticated using (true);
drop policy if exists ajustes_admin on public.ajustes;
create policy ajustes_admin on public.ajustes for all to authenticated using (public.es_admin()) with check (public.es_admin());
grant select, insert, update on public.ajustes to authenticated;

-- Cualquiera (incluso sin sesión) puede preguntar si un correo está invitado, para dar un mensaje claro antes de registrarse.
create or replace function public.correo_invitado(p_email text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select valor from public.ajustes where clave='registro_cerrado'),'true') <> 'true'
      or (select count(*) from public.perfiles) = 0
      or exists (select 1 from public.invitaciones where lower(email) = lower(trim(p_email)));
$$;
grant execute on function public.correo_invitado(text) to anon, authenticated;

-- Al crearse la cuenta: rechaza si no está invitado; si lo está, asigna rol y centro de la invitación.
create or replace function public.crear_perfil() returns trigger
language plpgsql security definer set search_path = public as $$
declare inv public.invitaciones; cerrado boolean; primero boolean;
begin
  primero := (select count(*) from public.perfiles) = 0;
  cerrado := coalesce((select valor from public.ajustes where clave='registro_cerrado'),'true') = 'true';
  select * into inv from public.invitaciones where lower(email) = lower(new.email);
  if cerrado and not primero and inv.email is null then
    raise exception 'Este correo no tiene invitación. Pide al coordinador del registro que te invite.';
  end if;
  insert into public.perfiles (user_id, email, nombre, rol, centro_id, sede, anio_res)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'nombre', split_part(new.email,'@',1)),
    case when primero then 'admin'
         when inv.email is not null then inv.rol
         when new.raw_user_meta_data->>'rol' = 'residente' then 'residente'
         else 'centro' end,
    inv.centro_id,
    new.raw_user_meta_data->>'sede',
    new.raw_user_meta_data->>'anio_res'
  )
  on conflict (user_id) do nothing;
  if inv.email is not null then update public.invitaciones set usado = now() where email = inv.email; end if;
  return new;
end $$;

-- El coordinador puede borrar una cuenta (perfil + usuario de auth). Sus pacientes se conservan en el centro.
create or replace function public.admin_borrar_usuario(p_user uuid) returns void
language plpgsql security definer set search_path = public, auth as $$
begin
  if not public.es_admin() then raise exception 'Solo administradores'; end if;
  if p_user = auth.uid() then raise exception 'No puedes borrar tu propia cuenta'; end if;
  delete from auth.users where id = p_user;
end $$;
grant execute on function public.admin_borrar_usuario(uuid) to authenticated;

-- ===== migracion_v4_panel =====
-- v4: el resumen anónimo de México incluye año y mes (nunca la fecha exacta) para la gráfica de pacientes por mes.
drop function if exists public.pacientes_anonimos(integer);
create or replace function public.pacientes_anonimos(p_anio integer default null)
returns table (sexo text, edad integer, imc numeric, dm2 boolean, has boolean, dislip boolean,
               tipo text, proc text, abordaje text, estancia integer, reop boolean, muerte boolean,
               origen text, sector text, glp1 boolean, anio integer, mes integer)
language sql stable security definer set search_path = public as $$
  select sexo, edad, imc, dm2, has, dislip, tipo, proc, abordaje, estancia, reop, muerte, origen, sector, glp1,
         extract(year from fecha)::integer, extract(month from fecha)::integer
  from public.pacientes
  where auth.uid() is not null and (p_anio is null or extract(year from fecha) = p_anio)
  order by random();
$$;
grant execute on function public.pacientes_anonimos(integer) to authenticated;

-- ===== migracion_v5_sedes =====
-- v5: sedes de residencia / fellowship en cirugía bariátrica (lista que administra el coordinador).
create table if not exists public.sedes (
  id      uuid primary key default gen_random_uuid(),
  nombre  text not null unique,
  ciudad  text,
  estado  text,
  activo  boolean not null default true,
  creado  timestamptz not null default now()
);
alter table public.sedes enable row level security;
drop policy if exists "sedes leer" on public.sedes;
create policy "sedes leer" on public.sedes for select to anon, authenticated using (true);
drop policy if exists "sedes admin" on public.sedes;
create policy "sedes admin" on public.sedes for all to authenticated using (public.es_admin()) with check (public.es_admin());
grant select on public.sedes to anon, authenticated;
grant insert, update, delete on public.sedes to authenticated;

-- ===== migracion_v6_terminos =====
-- v6: registro de aceptación del aviso de privacidad y términos de uso.
alter table public.perfiles add column if not exists terminos_aceptado timestamptz;
create or replace function public.crear_perfil() returns trigger
language plpgsql security definer set search_path = public as $$
declare inv public.invitaciones; cerrado boolean; primero boolean;
begin
  primero := (select count(*) from public.perfiles) = 0;
  cerrado := coalesce((select valor from public.ajustes where clave='registro_cerrado'),'true') = 'true';
  select * into inv from public.invitaciones where lower(email) = lower(new.email);
  if cerrado and not primero and inv.email is null then
    raise exception 'Este correo no tiene invitación. Pide al coordinador del registro que te invite.';
  end if;
  insert into public.perfiles (user_id, email, nombre, rol, centro_id, sede, anio_res, terminos_aceptado)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'nombre', split_part(new.email,'@',1)),
    case when primero then 'admin'
         when inv.email is not null then inv.rol
         when new.raw_user_meta_data->>'rol' = 'residente' then 'residente'
         else 'centro' end,
    inv.centro_id,
    new.raw_user_meta_data->>'sede',
    new.raw_user_meta_data->>'anio_res',
    nullif(new.raw_user_meta_data->>'acepto_terminos','')::timestamptz
  )
  on conflict (user_id) do nothing;
  if inv.email is not null then update public.invitaciones set usado = now() where email = inv.email; end if;
  return new;
end $$;

-- ===== migracion_v7_socios =====
-- v7: un socio = un centro. El coordinador solo carga la lista de correos de los socios;
-- al registrarse con un correo invitado, el socio crea su propio centro automáticamente
-- (nombre = su nombre, con ciudad, estado y hospitales donde opera).

alter table public.centros add column if not exists hospitales text;

-- Crea un centro con nombre único. Si el nombre ya existe, agrega la ciudad o un número.
create or replace function public._crear_centro_unico(p_nombre text, p_ciudad text, p_estado text, p_hospitales text) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_base text; v_nombre text; v_n int := 2; v_id uuid;
begin
  v_base := nullif(trim(p_nombre), '');
  if v_base is null then raise exception 'Falta el nombre del centro.'; end if;
  v_nombre := v_base;
  if nullif(trim(p_ciudad), '') is not null and exists (select 1 from public.centros c where lower(c.nombre) = lower(v_nombre)) then
    v_nombre := v_base || ' (' || trim(p_ciudad) || ')';
  end if;
  while exists (select 1 from public.centros c where lower(c.nombre) = lower(v_nombre)) loop
    v_nombre := v_base || ' (' || v_n || ')'; v_n := v_n + 1;
  end loop;
  insert into public.centros (nombre, ciudad, estado, hospitales)
  values (v_nombre, nullif(trim(p_ciudad), ''), nullif(trim(p_estado), ''), nullif(trim(p_hospitales), ''))
  returning id into v_id;
  return v_id;
end $$;
revoke all on function public._crear_centro_unico(text, text, text, text) from public;

-- Al crear la cuenta: si el correo está invitado como cirujano (o coordinador) y la invitación
-- no trae centro, se crea el centro del socio con los datos del formulario de alta.
create or replace function public.crear_perfil() returns trigger
language plpgsql security definer set search_path = public as $$
declare inv public.invitaciones; cerrado boolean; primero boolean; v_rol text; v_centro uuid; v_nombre text;
begin
  primero := (select count(*) from public.perfiles) = 0;
  cerrado := coalesce((select valor from public.ajustes where clave='registro_cerrado'),'true') = 'true';
  select * into inv from public.invitaciones where lower(email) = lower(new.email);
  if cerrado and not primero and inv.email is null then
    raise exception 'Este correo no tiene invitación. Pide al coordinador del registro que te invite.';
  end if;
  v_nombre := coalesce(nullif(trim(new.raw_user_meta_data->>'nombre'), ''), split_part(new.email,'@',1));
  v_rol := case when primero then 'admin'
                when inv.email is not null then inv.rol
                when new.raw_user_meta_data->>'rol' = 'residente' then 'residente'
                else 'centro' end;
  v_centro := inv.centro_id;
  if v_rol <> 'residente' and v_centro is null then
    v_centro := public._crear_centro_unico(v_nombre, new.raw_user_meta_data->>'ciudad', new.raw_user_meta_data->>'estado', new.raw_user_meta_data->>'hospitales');
  end if;
  insert into public.perfiles (user_id, email, nombre, rol, centro_id, sede, anio_res, terminos_aceptado)
  values (
    new.id, new.email, v_nombre, v_rol, v_centro,
    new.raw_user_meta_data->>'sede',
    new.raw_user_meta_data->>'anio_res',
    nullif(new.raw_user_meta_data->>'acepto_terminos','')::timestamptz
  )
  on conflict (user_id) do nothing;
  if inv.email is not null then update public.invitaciones set usado = now() where email = inv.email; end if;
  return new;
end $$;

-- Cuenta ya existente sin centro (por ejemplo, creada antes de v7): el propio usuario crea su centro.
create or replace function public.crear_mi_centro(p_ciudad text, p_estado text, p_hospitales text) returns uuid
language plpgsql security definer set search_path = public as $$
declare p public.perfiles; v_id uuid;
begin
  select * into p from public.perfiles where user_id = auth.uid();
  if p.user_id is null then raise exception 'Sin perfil.'; end if;
  if p.centro_id is not null then return p.centro_id; end if;
  if p.rol = 'residente' then raise exception 'Los residentes no tienen centro.'; end if;
  v_id := public._crear_centro_unico(coalesce(p.nombre, split_part(p.email,'@',1)), p_ciudad, p_estado, p_hospitales);
  update public.perfiles set centro_id = v_id where user_id = p.user_id;
  return v_id;
end $$;
grant execute on function public.crear_mi_centro(text, text, text) to authenticated;

-- ===== migracion_v8_borrar_usuario =====
-- v8: al borrar una cuenta, su invitación vuelve a "Pendiente" y sin centro,
-- para que ese correo pueda registrarse de nuevo y crear su propio centro.
create or replace function public.admin_borrar_usuario(p_user uuid) returns void
language plpgsql security definer set search_path = public, auth as $$
declare v_email text;
begin
  if not public.es_admin() then raise exception 'Solo administradores'; end if;
  if p_user = auth.uid() then raise exception 'No puedes borrar tu propia cuenta'; end if;
  select email into v_email from auth.users where id = p_user;
  delete from auth.users where id = p_user;
  if v_email is not null then
    update public.invitaciones set usado = null, centro_id = null where lower(email) = lower(v_email);
  end if;
end $$;
grant execute on function public.admin_borrar_usuario(uuid) to authenticated;

-- ===== migracion_v9_comorbilidades =====
-- v9: comorbilidades ampliadas (además de DM2, HAS y dislipidemia):
-- prediabetes, resistencia a la insulina, SAOS, ERGE, MASLD (hígado graso), SOP, osteoartrosis,
-- hipotiroidismo y depresión/ansiedad. Mismas columnas en pacientes y en residentes_casos.
alter table public.pacientes
  add column if not exists prediabetes    boolean not null default false,
  add column if not exists resist_ins     boolean not null default false,
  add column if not exists saos           boolean not null default false,
  add column if not exists erge           boolean not null default false,
  add column if not exists masld          boolean not null default false,
  add column if not exists sop            boolean not null default false,
  add column if not exists osteoartrosis  boolean not null default false,
  add column if not exists hipotiroidismo boolean not null default false,
  add column if not exists depresion      boolean not null default false;
alter table public.residentes_casos
  add column if not exists prediabetes    boolean not null default false,
  add column if not exists resist_ins     boolean not null default false,
  add column if not exists saos           boolean not null default false,
  add column if not exists erge           boolean not null default false,
  add column if not exists masld          boolean not null default false,
  add column if not exists sop            boolean not null default false,
  add column if not exists osteoartrosis  boolean not null default false,
  add column if not exists hipotiroidismo boolean not null default false,
  add column if not exists depresion      boolean not null default false;

-- El resumen anónimo de México incluye las nuevas comorbilidades (sigue sin fecha exacta ni folio).
drop function if exists public.pacientes_anonimos(integer);
create or replace function public.pacientes_anonimos(p_anio integer default null)
returns table (sexo text, edad integer, imc numeric, dm2 boolean, has boolean, dislip boolean,
               tipo text, proc text, abordaje text, estancia integer, reop boolean, muerte boolean,
               origen text, sector text, glp1 boolean, anio integer, mes integer,
               prediabetes boolean, resist_ins boolean, saos boolean, erge boolean, masld boolean,
               sop boolean, osteoartrosis boolean, hipotiroidismo boolean, depresion boolean)
language sql stable security definer set search_path = public as $$
  select sexo, edad, imc, dm2, has, dislip, tipo, proc, abordaje, estancia, reop, muerte, origen, sector, glp1,
         extract(year from fecha)::integer, extract(month from fecha)::integer,
         prediabetes, resist_ins, saos, erge, masld, sop, osteoartrosis, hipotiroidismo, depresion
  from public.pacientes
  where auth.uid() is not null and (p_anio is null or extract(year from fecha) = p_anio)
  order by random();
$$;
grant execute on function public.pacientes_anonimos(integer) to authenticated;

-- ===== migracion_v10_peso_talla =====
-- v10: peso (kg) y talla (cm) opcionales; el IMC se sigue guardando como siempre
-- (la app lo calcula sola cuando hay peso y talla).
alter table public.pacientes
  add column if not exists peso  numeric(5,1) check (peso is null or peso between 20 and 400),
  add column if not exists talla numeric(5,1) check (talla is null or talla between 100 and 250);
alter table public.residentes_casos
  add column if not exists peso  numeric(5,1) check (peso is null or peso between 20 and 400),
  add column if not exists talla numeric(5,1) check (talla is null or talla between 100 and 250);

-- ===== migracion_v11_correos_invitacion =====
-- v11: seguimiento de los correos de invitación automáticos (los manda el workflow
-- "Correos de invitación" del repo privado respaldos, cada hora, vía Resend).
alter table public.invitaciones
  add column if not exists enviado          timestamptz,            -- primera invitación enviada
  add column if not exists ultimo_correo    timestamptz,            -- último correo (invitación o recordatorio)
  add column if not exists recordatorios    smallint not null default 0,
  add column if not exists reenviar         boolean not null default false,  -- el coordinador pidió reenviar
  add column if not exists correos_pausados boolean not null default false;  -- no mandarle más correos

-- ===== migracion_v12_tore =====
-- v12: nuevo procedimiento "tore" (TORe, reducción endoscópica de la anastomosis gastroyeyunal).
alter table public.pacientes drop constraint if exists pacientes_proc_check;
alter table public.pacientes add constraint pacientes_proc_check
  check (proc in ('manga','oagb','bypass','sadis','oatb','biparticion','manga_endo','tore','allurion','balon','otra'));
alter table public.residentes_casos drop constraint if exists residentes_casos_proc_check;
alter table public.residentes_casos add constraint residentes_casos_proc_check
  check (proc in ('manga','oagb','bypass','sadis','oatb','biparticion','manga_endo','tore','allurion','balon','otra'));

-- ===== migracion_v13_cv_renal =====
-- v13: dos comorbilidades más: antecedente de enfermedad cardiovascular mayor (IAM / EVC / angina)
-- y falla renal. Mismas columnas en pacientes y en residentes_casos.
alter table public.pacientes
  add column if not exists ecv_mayor   boolean not null default false,
  add column if not exists falla_renal boolean not null default false;
alter table public.residentes_casos
  add column if not exists ecv_mayor   boolean not null default false,
  add column if not exists falla_renal boolean not null default false;

-- El resumen anónimo de México incluye las dos nuevas (sigue sin fecha exacta ni folio).
drop function if exists public.pacientes_anonimos(integer);
create or replace function public.pacientes_anonimos(p_anio integer default null)
returns table (sexo text, edad integer, imc numeric, dm2 boolean, has boolean, dislip boolean,
               tipo text, proc text, abordaje text, estancia integer, reop boolean, muerte boolean,
               origen text, sector text, glp1 boolean, anio integer, mes integer,
               prediabetes boolean, resist_ins boolean, saos boolean, erge boolean, masld boolean,
               sop boolean, osteoartrosis boolean, hipotiroidismo boolean, depresion boolean,
               ecv_mayor boolean, falla_renal boolean)
language sql stable security definer set search_path = public as $$
  select sexo, edad, imc, dm2, has, dislip, tipo, proc, abordaje, estancia, reop, muerte, origen, sector, glp1,
         extract(year from fecha)::integer, extract(month from fecha)::integer,
         prediabetes, resist_ins, saos, erge, masld, sop, osteoartrosis, hipotiroidismo, depresion,
         ecv_mayor, falla_renal
  from public.pacientes
  where auth.uid() is not null and (p_anio is null or extract(year from fecha) = p_anio)
  order by random();
$$;
grant execute on function public.pacientes_anonimos(integer) to authenticated;

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

-- ===== migracion_v16_sin_cuenta =====
-- v16: al fallar "Entrar", la app pregunta si el correo está invitado y aún no tiene cuenta, para guiar al socio.
create or replace function public.sin_cuenta(p_email text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.invitaciones i where lower(i.email) = lower(trim(p_email)))
     and not exists (select 1 from public.perfiles p where lower(p.email) = lower(trim(p_email)));
$$;
grant execute on function public.sin_cuenta(text) to anon, authenticated;
-- ===== migracion_v17_correos_pgcron =====
-- v17: los correos de invitación y recordatorios se envían desde la propia base de datos cada 10 minutos
-- (pg_cron + pg_net → API de Resend), en lugar de GitHub Actions, cuyo horario en cuentas gratuitas se retrasa horas.
-- La clave de Resend se guarda en Vault con el nombre 'resend_api_key' (la pone el coordinador una sola vez):
--   select vault.create_secret('re_xxxxxxxx', 'resend_api_key');
create extension if not exists pg_cron;
create extension if not exists pg_net;

-- Bitácora de cada correo que sale (para auditar y detectar rebotes/errores).
create table if not exists public.correos_log (
  id bigserial primary key,
  email text not null,
  tipo text not null,              -- invitacion | recordatorio1 | recordatorio2
  request_id bigint,               -- id de pg_net
  estado text not null default 'enviado',  -- enviado | ok | error
  detalle text,
  creado timestamptz not null default now()
);
alter table public.correos_log enable row level security;
drop policy if exists correos_log_admin on public.correos_log;
create policy correos_log_admin on public.correos_log for select to authenticated using (public.es_admin());
grant select on public.correos_log to authenticated;

create or replace function public.cuerpo_invitacion(p_email text, p_rol text, p_tipo text,
  out asunto text, out texto text, out html text)
language plpgsql immutable as $$
declare
  base constant text := 'https://registrobariatrico.com/';
  res boolean := p_rol = 'residente';
  liga text; titulo text; intro text; pie text; pasos text[]; li text := ''; p text; n int := 0;
begin
  liga := base || case when res then 'residentes/' else 'app/' end;
  if res then
    pasos := array['Abre ' || liga, 'Toca "Soy residente, crear mi cuenta" usando este correo: ' || p_email,
      'Captura cada cirugía en la que participes. Tu bitácora es personal y puedes descargarla en Excel cuando la necesites.'];
    titulo := 'Bitácora de Residentes – Registro Bariátrico México';
  else
    pasos := array['Abre ' || liga, 'Toca "Crear cuenta nueva" usando este correo: ' || p_email,
      'Escribe tu nombre, ciudad y hospital(es) donde operas; tu centro queda creado en ese momento.',
      'Listo: captura cada paciente operado; toma menos de un minuto.'];
    titulo := 'Registro Bariátrico México';
  end if;
  if p_tipo = 'invitacion' then
    asunto := titulo || ': tu acceso está listo';
    intro := 'El Colegio Mexicano de Cirugía para la Obesidad y Enfermedades Metabólicas (CMCOEM) te da acceso al Registro Bariátrico México, la plataforma donde cada socio registra sus pacientes y ve sus propias estadísticas al momento. Los datos no llevan nombres de pacientes y ningún centro ve los de otro.';
  elsif p_tipo = 'recordatorio1' then
    asunto := titulo || ': recordatorio para crear tu cuenta';
    intro := 'Hace unos días te enviamos el acceso al Registro Bariátrico México y vemos que todavía no has creado tu cuenta. Son dos minutos y solo necesitas este correo.';
  else
    asunto := titulo || ': último recordatorio';
    intro := 'Este es el último recordatorio para crear tu cuenta en el Registro Bariátrico México. Si prefieres no participar por ahora, simplemente ignora este correo; cuando quieras entrar, el acceso seguirá abierto.';
  end if;
  pie := 'Desde el celular puedes instalarlo como app con el botón "Instalar app".' || chr(10) || 'Dudas: contacto@registrobariatrico.com';
  texto := titulo || chr(10) || chr(10) || intro || chr(10) || chr(10);
  foreach p in array pasos loop
    n := n + 1;
    texto := texto || n || '. ' || p || chr(10);
    li := li || '<li style=''margin:6px 0''>' || replace(p, liga, '<a href="' || liga || '">' || liga || '</a>') || '</li>';
  end loop;
  texto := texto || chr(10) || pie;
  html := '<div style=''font-family:Roboto,Arial,sans-serif;max-width:560px;margin:0 auto;color:#1b1b1f;font-size:16px;line-height:1.5''>'
       || '<h2 style=''color:#061551;margin:24px 0 8px''>' || titulo || '</h2><p>' || intro || '</p><ol style=''padding-left:22px''>' || li || '</ol>'
       || '<p style=''margin:24px 0''><a href=''' || liga || ''' style=''background:#844dff;color:#fff;text-decoration:none;padding:12px 22px;border-radius:999px;font-weight:600''>Entrar al registro</a></p>'
       || '<p style=''color:#5a5a66;font-size:14px''>' || replace(pie, chr(10), '<br>') || '</p></div>';
end $$;

-- Revisa las invitaciones pendientes y envía lo que toque. Tope diario p_max (plan gratis de Resend: 100/día).
create or replace function public.enviar_invitaciones(p_max int default 90) returns int
language plpgsql security definer set search_path = public as $$
declare
  k text; inv record; tipo text; hoy int; enviados int := 0; rid bigint; c record;
begin
  select decrypted_secret into k from vault.decrypted_secrets where name = 'resend_api_key' limit 1;
  if k is null then raise notice 'Falta el secreto resend_api_key en Vault'; return 0; end if;
  select count(*) into hoy from public.correos_log where creado >= date_trunc('day', now());
  for inv in select * from public.invitaciones where usado is null and not coalesce(correos_pausados, false) order by creado loop
    exit when hoy + enviados >= p_max;
    if inv.enviado is null or coalesce(inv.reenviar, false) then tipo := 'invitacion';
    elsif coalesce(inv.recordatorios, 0) = 0 and inv.ultimo_correo is not null and now() - inv.ultimo_correo >= interval '5 days' then tipo := 'recordatorio1';
    elsif coalesce(inv.recordatorios, 0) = 1 and inv.ultimo_correo is not null and now() - inv.ultimo_correo >= interval '7 days' then tipo := 'recordatorio2';
    else continue;
    end if;
    select * into c from public.cuerpo_invitacion(inv.email, inv.rol, tipo);
    select net.http_post(
      url := 'https://api.resend.com/emails',
      headers := jsonb_build_object('Authorization', 'Bearer ' || k, 'Content-Type', 'application/json',
                                    'User-Agent', 'registro-bariatrico-db/1.0 (contacto@registrobariatrico.com)'),
      body := jsonb_build_object('from', 'Registro Bariátrico México <contacto@registrobariatrico.com>',
                                 'to', jsonb_build_array(inv.email), 'reply_to', 'contacto@registrobariatrico.com',
                                 'subject', c.asunto, 'text', c.texto, 'html', c.html),
      timeout_milliseconds := 15000) into rid;
    if tipo = 'invitacion' then
      update public.invitaciones set enviado = now(), ultimo_correo = now(), recordatorios = 0, reenviar = false where email = inv.email;
    elsif tipo = 'recordatorio1' then
      update public.invitaciones set ultimo_correo = now(), recordatorios = 1 where email = inv.email;
    else
      update public.invitaciones set ultimo_correo = now(), recordatorios = 2 where email = inv.email;
    end if;
    insert into public.correos_log (email, tipo, request_id) values (inv.email, tipo, rid);
    enviados := enviados + 1;
  end loop;
  return enviados;
end $$;

-- Marca en la bitácora la respuesta de Resend (pg_net responde de forma asíncrona).
create or replace function public.revisar_envios() returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update public.correos_log l set estado = case when r.status_code between 200 and 299 then 'ok' else 'error' end,
         detalle = left(coalesce(r.error_msg, r.content::text), 300)
  from net._http_response r
  where r.id = l.request_id and l.estado = 'enviado';
  get diagnostics n = row_count;
  return n;
end $$;

revoke all on function public.enviar_invitaciones(int) from public, anon, authenticated;
revoke all on function public.revisar_envios() from public, anon, authenticated;

-- Programación: envíos cada 10 minutos; revisión de respuestas 3 minutos después.
select cron.unschedule(jobid) from cron.job where jobname in ('invitaciones_10min', 'invitaciones_revisar');
select cron.schedule('invitaciones_10min', '*/10 * * * *', $$select public.enviar_invitaciones()$$);
select cron.schedule('invitaciones_revisar', '3-59/10 * * * *', $$select public.revisar_envios()$$);
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
-- ===== migracion_v20_seg_activar =====
-- v20: el socio puede activar/desactivar el seguimiento de SU centro (solo esa columna).
create or replace function public.centro_seguimiento(p_activo boolean)
returns void
language sql security definer set search_path = public as $$
  update public.centros set seguimiento = p_activo where id = public.mi_centro();
$$;
revoke all on function public.centro_seguimiento(boolean) from public, anon;
grant execute on function public.centro_seguimiento(boolean) to authenticated;
-- ===== migracion_v21_avisos =====
-- v21: avisos al socio cuando Coordinación acepta o rechaza su carta y cuando emite su constancia.
--  · Correo inmediato (Resend, misma llave del Vault) + notificación en el celular (cola que vacía el
--    workflow "Recordatorios de seguimiento", que ahora corre cada hora). Sin datos de pacientes.
create table if not exists public.push_cola (
  id bigserial primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  titulo text not null,
  cuerpo text not null,
  url text not null default '/app/#constancia',
  creado timestamptz not null default now(),
  enviado timestamptz
);
alter table public.push_cola enable row level security;  -- solo la service key la lee

create or replace function public.notificar_socio(p_centro uuid, p_tipo text, p_asunto text, p_titulo text, p_cuerpo text, p_url text)
returns void language plpgsql security definer set search_path = public as $$
declare k text; r record; rid bigint; liga text := 'https://registrobariatrico.com' || p_url; htm text;
begin
  for r in select pf.user_id, pf.email, pf.nombre from public.perfiles pf where pf.centro_id = p_centro and pf.rol = 'centro' loop
    insert into public.push_cola (user_id, titulo, cuerpo, url) values (r.user_id, p_titulo, p_cuerpo, p_url);
    if r.email is not null then
      select decrypted_secret into k from vault.decrypted_secrets where name = 'resend_api_key' limit 1;
      if k is not null then
        htm := '<div style=''font-family:Roboto,Arial,sans-serif;max-width:560px;margin:0 auto;color:#1b1b1f;font-size:16px;line-height:1.5''>'
          || '<h2 style=''color:#061551;margin:24px 0 8px''>' || p_titulo || '</h2><p>Dr(a). ' || coalesce(r.nombre, '') || ':</p><p>' || p_cuerpo || '</p>'
          || '<p style=''margin:24px 0''><a href=''' || liga || ''' style=''background:#844dff;color:#fff;text-decoration:none;padding:12px 22px;border-radius:999px;font-weight:600''>Abrir el registro</a></p>'
          || '<p style=''color:#5a5a66;font-size:14px''>Dudas: contacto@registrobariatrico.com</p></div>';
        select net.http_post(url := 'https://api.resend.com/emails',
          headers := jsonb_build_object('Authorization', 'Bearer ' || k, 'Content-Type', 'application/json'),
          body := jsonb_build_object('from', 'Registro Bariátrico México <contacto@registrobariatrico.com>',
            'to', jsonb_build_array(r.email), 'reply_to', 'contacto@registrobariatrico.com',
            'subject', p_asunto, 'text', 'Dr(a). ' || coalesce(r.nombre, '') || ': ' || p_cuerpo || chr(10) || chr(10) || liga, 'html', htm),
          timeout_milliseconds := 15000) into rid;
        insert into public.correos_log (email, tipo, request_id) values (r.email, p_tipo, rid);
      end if;
    end if;
  end loop;
end $$;
revoke all on function public.notificar_socio(uuid, text, text, text, text, text) from public, anon, authenticated;

-- Carta aceptada o rechazada
create or replace function public.cartas_aviso() returns trigger
language plpgsql security definer set search_path = public as $$
declare h text;
begin
  if new.estado is distinct from old.estado and new.estado in ('aceptada', 'rechazada') then
    select nombre into h from public.hospitales where id = new.hospital_id;
    if new.estado = 'aceptada' then
      perform public.notificar_socio(new.centro_id, 'carta_aceptada_' || new.anio,
        'Registro Bariátrico México: carta de ' || coalesce(h, 'hospital') || ' aceptada',
        'Carta aceptada', 'Coordinación aceptó la carta de ' || coalesce(h, 'tu hospital') || ' del año ' || new.anio || '. Cuando todas tus cartas estén aceptadas, se emitirá tu constancia.', '/app/#constancia');
    else
      perform public.notificar_socio(new.centro_id, 'carta_rechazada_' || new.anio,
        'Registro Bariátrico México: carta de ' || coalesce(h, 'hospital') || ' rechazada',
        'Carta rechazada', 'Coordinación rechazó la carta de ' || coalesce(h, 'tu hospital') || ' del año ' || new.anio || '. Motivo: ' || coalesce(new.motivo, 'sin motivo') || '. Puedes subir una carta corregida desde la pestaña Constancia.', '/app/#constancia');
    end if;
  end if;
  return new;
end $$;
drop trigger if exists cartas_aviso on public.cartas;
create trigger cartas_aviso after update on public.cartas for each row execute function public.cartas_aviso();

-- Constancia emitida
create or replace function public.constancias_aviso() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.estado = 'emitida' and old.estado is distinct from 'emitida' then
    perform public.notificar_socio(new.centro_id, 'constancia_emitida_' || new.anio,
      'Registro Bariátrico México: tu constancia ' || new.anio || ' está lista (folio ' || new.folio || ')',
      'Tu constancia ' || new.anio || ' está lista',
      'Coordinación emitió tu constancia de participación ' || new.anio || ' con folio ' || new.folio || '. Descárgala en PDF con código QR desde la pestaña Constancia.', '/app/#constancia');
  end if;
  return new;
end $$;
drop trigger if exists constancias_aviso on public.constancias;
create trigger constancias_aviso after update on public.constancias for each row execute function public.constancias_aviso();
