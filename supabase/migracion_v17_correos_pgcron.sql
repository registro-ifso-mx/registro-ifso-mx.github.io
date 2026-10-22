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
