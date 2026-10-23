import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.4";

const projectUrl = Deno.env.get("SUPABASE_URL") ?? "";
const anonKey = getDefaultApiKey("SUPABASE_PUBLISHABLE_KEYS", "SUPABASE_ANON_KEY");
const serviceRoleKey = getDefaultApiKey("SUPABASE_SECRET_KEYS", "SUPABASE_SERVICE_ROLE_KEY");
const allowedOrigin = Deno.env.get("ALLOWED_ORIGIN") ?? "";

function getDefaultApiKey(keysVariable: string, legacyVariable: string) {
  const keysJson = Deno.env.get(keysVariable);
  if (keysJson) {
    try {
      const keys: unknown = JSON.parse(keysJson);
      if (keys && typeof keys === "object" && "default" in keys && typeof keys.default === "string") {
        return keys.default;
      }
    } catch (error) {
      console.error(`No se pudo leer ${keysVariable}.`, error);
      return "";
    }
    console.error(`No se encontró una clave default válida en ${keysVariable}.`);
    return "";
  }
  return Deno.env.get(legacyVariable) ?? "";
}

const corsHeaders = {
  "Access-Control-Allow-Origin": allowedOrigin,
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Vary": "Origin"
};

function jsonResponse(body: Record<string, string>, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" }
  });
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (request.method !== "POST") {
    return jsonResponse({ error: "Método no permitido." }, 405);
  }

  if (!projectUrl || !anonKey || !serviceRoleKey || !allowedOrigin) {
    console.error("Falta configurar uno o más secretos de create-user.");
    return jsonResponse({ error: "El servicio de creación de cuentas no está configurado." }, 500);
  }

  if (request.headers.get("origin") !== allowedOrigin) {
    return jsonResponse({ error: "Origen no autorizado." }, 403);
  }

  const authorization = request.headers.get("authorization");
  if (!authorization?.startsWith("Bearer ")) {
    return jsonResponse({ error: "Inicia sesión como administrador." }, 401);
  }

  const userClient = createClient(projectUrl, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { autoRefreshToken: false, persistSession: false }
  });
  const userData = await userClient.auth.getUser().catch((error: unknown) => {
    console.error("No se pudo validar la sesión del administrador.", error);
    return undefined;
  });
  if (!userData) {
    return jsonResponse({ error: "No se pudo validar tu sesión. Inténtalo de nuevo." }, 502);
  }
  if (userData.error || !userData.data.user) {
    return jsonResponse({ error: "La sesión no es válida. Inicia sesión de nuevo." }, 401);
  }

  const profileResult = await userClient
    .from("profiles")
    .select("role")
    .eq("id", userData.data.user.id)
    .single()
    .then((result) => ({ kind: "success" as const, result }))
    .catch((error: unknown) => ({ kind: "error" as const, error }));
  if (profileResult.kind === "error") {
    console.error("No se pudo comprobar el rol del administrador.", profileResult.error);
    return jsonResponse({ error: "No se pudo comprobar tu rol. Inténtalo de nuevo." }, 502);
  }
  if (profileResult.result.error || profileResult.result.data.role !== "admin") {
    return jsonResponse({ error: "Solo una persona administradora puede crear cuentas." }, 403);
  }

  let requestBody: unknown;
  try {
    requestBody = await request.json();
  } catch {
    return jsonResponse({ error: "Los datos de la cuenta no son válidos." }, 400);
  }
  if (!requestBody || typeof requestBody !== "object" || Array.isArray(requestBody)) {
    return jsonResponse({ error: "Los datos de la cuenta no son válidos." }, 400);
  }

  const body = requestBody as Record<string, unknown>;
  const username = typeof body.username === "string" ? body.username.trim().toLowerCase() : "";
  const displayName = typeof body.displayName === "string" ? body.displayName.trim() : "";
  const password = typeof body.password === "string" ? body.password : "";
  const passwordLength = new TextEncoder().encode(password).length;

  if (!/^[a-z0-9][a-z0-9._-]{2,31}$/.test(username)) {
    return jsonResponse({ error: "El usuario debe tener de 3 a 32 caracteres: letras, números, punto, guion o guion bajo." }, 400);
  }
  if (displayName.length < 1 || displayName.length > 80) {
    return jsonResponse({ error: "El nombre debe tener entre 1 y 80 caracteres." }, 400);
  }
  if (passwordLength < 8 || passwordLength > 72) {
    return jsonResponse({ error: "La contraseña debe tener entre 8 y 72 bytes." }, 400);
  }

  const adminClient = createClient(projectUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false }
  });
  const createResult = await adminClient.auth.admin.createUser({
    email: `${username}@accounts.peps.invalid`,
    password,
    email_confirm: true,
    user_metadata: { username, display_name: displayName }
  }).catch((error: unknown) => {
    console.error("Falló la creación de la cuenta.", error);
    return undefined;
  });
  if (!createResult) {
    return jsonResponse({ error: "Ocurrió un error al crear la cuenta. Inténtalo de nuevo." }, 502);
  }
  if (createResult.error) {
    console.error("Supabase rechazó la creación de la cuenta.", createResult.error);
    return jsonResponse({ error: "No se pudo crear la cuenta. Comprueba que el usuario no exista." }, 400);
  }

  return jsonResponse({ message: `Cuenta creada. Usuario: ${username}. Comparte la contraseña de forma segura.` }, 200);
});
