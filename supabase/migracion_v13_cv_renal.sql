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
