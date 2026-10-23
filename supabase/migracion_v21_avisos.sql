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
