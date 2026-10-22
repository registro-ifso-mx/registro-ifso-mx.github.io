// Configuración de la app. Estos dos valores vienen de Supabase → Project Settings → API.
// La "anon key" es pública por diseño: la seguridad está en las reglas de la base de datos (RLS).
window.IFSO_CONFIG = {
  SUPABASE_URL: "https://yqzwvnfzryyvuqfgqwys.supabase.co",
  SUPABASE_ANON_KEY: "sb_publishable_DyNe5-5Yq3IcoPQIRrfcDQ_WZo3hm_D",
  NOMBRE_REGISTRO: "Registro Bariátrico México",
  ORGANIZACION: "Colegio Mexicano de Cirugía para la Obesidad y Enfermedades Metabólicas",
  // Clave pública para las notificaciones de seguimiento (Web Push / VAPID). La privada vive en los secretos del repo respaldos.
  VAPID_PUBLIC: "BMjquX5VogrFKCUjJDHF5SU193Kf5xjiJsOt4iwDbieoRSjeoEiqyrmJBie1nuAGxdlAQa_1wk4Ig9b19i6bvvk"
};
