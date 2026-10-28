import { createClient } from "npm:@supabase/supabase-js@2";

const allowedOrigin = "https://logisstant.vercel.app";
const headers = {
  "Access-Control-Allow-Origin": allowedOrigin,
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};
function respond(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), { status, headers });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers });
  if (req.method !== "POST") return respond({ error: "Method not allowed" }, 405);

  const authorization = req.headers.get("Authorization");
  const token = authorization?.replace(/^Bearer\s+/i, "");
  if (!token) return respond({ error: "Authentication required" }, 401);

  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anonKey || !serviceKey) return respond({ error: "Account service is not configured" }, 500);

  const userClient = createClient(url, anonKey, { auth: { autoRefreshToken: false, persistSession: false } });
  const admin = createClient(url, serviceKey, { auth: { autoRefreshToken: false, persistSession: false } });
  const { data: authData, error: authError } = await userClient.auth.getUser(token);
  const user = authData?.user;
  if (authError || !user || !user.email) return respond({ error: "Session is invalid. Sign in again." }, 401);

  let body: { confirmEmail?: string };
  try { body = await req.json(); } catch { return respond({ error: "Invalid request body" }, 400); }
  if (typeof body.confirmEmail !== "string" || body.confirmEmail.trim().toLowerCase() !== user.email.toLowerCase()) {
    return respond({ error: "Email confirmation did not match" }, 400);
  }

  const { data: ownedOrganizations, error: ownerError } = await admin
    .from("organization_members")
    .select("organization_id")
    .eq("user_id", user.id)
    .eq("role", "owner");
  if (ownerError) return respond({ error: "Could not verify firm ownership" }, 500);
  if (ownedOrganizations?.length) {
    return respond({
      code: "OWNER_TRANSFER_REQUIRED",
      error: "OWNER_TRANSFER_REQUIRED",
      message: "Transfer ownership of each firm before closing this account.",
    }, 409);
  }

  // Preserve business records while removing personal references to this account.
  const cleanups = await Promise.all([
    admin.from("organizations").update({ created_by: null }).eq("created_by", user.id),
    admin.from("offers").update({ created_by: null }).eq("created_by", user.id),
    admin.from("shipments").update({ created_by: null }).eq("created_by", user.id),
    admin.from("shipment_documents").update({ uploaded_by: null }).eq("uploaded_by", user.id),
    admin.from("shipment_events").update({ actor_id: null, actor_name: "Hesap kapatıldı" }).eq("actor_id", user.id),
    admin.from("email_delivery_alert_log").delete().eq("user_id", user.id),
  ]);
  const cleanupError = cleanups.find((result) => result.error)?.error;
  if (cleanupError) return respond({ error: "Could not safely prepare account data for closure", message: cleanupError.message }, 500);

  const { error: deleteError } = await admin.auth.admin.deleteUser(user.id);
  if (deleteError) {
    return respond({
      error: "Account could not be deleted. If this account uploaded private files, transfer their ownership to another firm administrator first.",
      message: deleteError.message,
    }, 409);
  }
  return respond({ success: true, preserved: ["organizations", "offers", "shipments", "shipment_documents"] });
});