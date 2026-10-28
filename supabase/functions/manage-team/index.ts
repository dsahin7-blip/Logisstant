import { createClient } from "npm:@supabase/supabase-js@2";

const allowedOrigin = "https://logisstant.vercel.app";
const corsHeaders = {
  "Access-Control-Allow-Origin": allowedOrigin,
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};
function respond(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: corsHeaders });
}
Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return respond({ error: "Method not allowed." }, 405);
  if (req.headers.get("origin") && req.headers.get("origin") !== allowedOrigin) return respond({ error: "Origin not allowed." }, 403);
  const authorization = req.headers.get("Authorization") || "";
  const token = authorization.toLowerCase().startsWith("bearer ") ? authorization.slice(7).trim() : authorization.trim();
  const url = Deno.env.get("SUPABASE_URL"), serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!token || !url || !serviceKey) return respond({ error: "Team service is not configured." }, 500);
  const admin = createClient(url, serviceKey, { auth: { autoRefreshToken: false, persistSession: false } });
  const { data: authData, error: authError } = await admin.auth.getUser(token);
  const user = authData?.user;
  if (authError || !user) return respond({ error: "Please sign in again." }, 401);
  let body: { action?: string; organization_id?: string; user_id?: string; role?: string; customer_id?: string | null };
  try { body = await req.json(); } catch { return respond({ error: "Invalid request." }, 400); }
  const organizationId = body.organization_id;
  if (!organizationId) return respond({ error: "Organization is required." }, 400);
  const { data: actor, error: actorError } = await admin.from("organization_members").select("role")
    .eq("organization_id", organizationId).eq("user_id", user.id).maybeSingle();
  if (actorError || !actor || !["owner", "admin"].includes(actor.role)) return respond({ error: "Only organization owners and admins can manage members." }, 403);
  if (body.action === "list") {
    const { data: rows, error } = await admin.from("organization_members")
      .select("user_id, role, customer_id, created_at").eq("organization_id", organizationId).order("created_at");
    if (error) return respond({ error: "Could not load team members." }, 500);
    const members = await Promise.all((rows || []).map(async (row) => {
      const [{ data: profile }, { data: customer }, { data: auth }] = await Promise.all([
        admin.from("profiles").select("full_name").eq("id", row.user_id).maybeSingle(),
        row.customer_id ? admin.from("customers").select("name").eq("id", row.customer_id).maybeSingle() : Promise.resolve({ data: null }),
        admin.auth.admin.getUserById(row.user_id),
      ]);
      return { user_id: row.user_id, role: row.role, customer_id: row.customer_id, name: profile?.full_name || "", email: auth?.user?.email || "", customer_name: customer?.name || "" };
    }));
    return respond({ members });
  }
  const targetId = body.user_id;
  if (!targetId || targetId === user.id) return respond({ error: "Choose another team member." }, 400);
  const { data: target, error: targetError } = await admin.from("organization_members")
    .select("role").eq("organization_id", organizationId).eq("user_id", targetId).maybeSingle();
  if (targetError || !target) return respond({ error: "Team member not found." }, 404);
  if (body.action === "transfer_owner") {
    if (actor.role !== "owner") return respond({ error: "Only the current owner can transfer ownership." }, 403);
    if (target.role === "owner" || target.role === "client") return respond({ error: "Choose an internal team member." }, 400);
    const { error: promoteError } = await admin.from("organization_members").update({ role: "owner", customer_id: null })
      .eq("organization_id", organizationId).eq("user_id", targetId);
    if (promoteError) return respond({ error: "Could not transfer ownership." }, 500);
    const { error: demoteError } = await admin.from("organization_members").update({ role: "admin", customer_id: null })
      .eq("organization_id", organizationId).eq("user_id", user.id);
    if (demoteError) return respond({ error: "Ownership transferred, but your previous owner role could not be changed. Both accounts still have owner access." }, 500);
    return respond({ ok: true });
  }
  if (["owner", "admin"].includes(target.role)) return respond({ error: "Owner and admin access cannot be changed here." }, 403);
  if (body.action === "remove") {
    const { error } = await admin.from("organization_members").delete().eq("organization_id", organizationId).eq("user_id", targetId);
    if (error) return respond({ error: "Could not remove team access." }, 500);
    return respond({ ok: true });
  }
  if (body.action !== "update" || !["operations", "finance", "client"].includes(body.role || "")) return respond({ error: "Choose a valid role." }, 400);
  const role = body.role!, customerId = body.customer_id || null;
  if (role === "client") {
    if (!customerId) return respond({ error: "Choose a customer for client access." }, 400);
    const { data: customer } = await admin.from("customers").select("id").eq("id", customerId).eq("organization_id", organizationId).maybeSingle();
    if (!customer) return respond({ error: "The selected customer does not belong to this organization." }, 400);
  } else if (customerId) return respond({ error: "Internal team members cannot be linked to a customer." }, 400);
  const { error } = await admin.from("organization_members").update({ role, customer_id: customerId })
    .eq("organization_id", organizationId).eq("user_id", targetId);
  if (error) return respond({ error: "Could not update team access." }, 500);
  return respond({ ok: true });
});