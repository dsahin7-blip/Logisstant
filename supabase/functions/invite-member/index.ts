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
  if (req.headers.get("origin") && req.headers.get("origin") !== allowedOrigin) {
    return respond({ error: "Origin not allowed." }, 403);
  }

  const authorization = req.headers.get("Authorization") || "";
  const token = authorization.replace(/^Bearer\\s+/i, "");
  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!token || !url || !serviceKey) return respond({ error: "Invitation service is not configured." }, 500);

  const admin = createClient(url, serviceKey, { auth: { autoRefreshToken: false, persistSession: false } });
  const { data: authData, error: authError } = await admin.auth.getUser(token);
  const user = authData?.user;
  if (authError || !user) return respond({ error: "Please sign in again before inviting a user." }, 401);

  let body: { organization_id?: string; email?: string; role?: string; customer_id?: string | null };
  try { body = await req.json(); } catch { return respond({ error: "Invalid request." }, 400); }

  const organizationId = body.organization_id;
  const email = (body.email || "").trim().toLowerCase();
  const role = body.role;
  const customerId = body.customer_id || null;
  if (!organizationId || !/^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$/.test(email) || !["operations", "finance", "client"].includes(role || "")) {
    return respond({ error: "Check the email, role, and organization." }, 400);
  }
  if (email === (user.email || "").toLowerCase()) return respond({ error: "You cannot invite your own email address." }, 400);

  const { data: inviter, error: inviterError } = await admin.from("organization_members")
    .select("role").eq("organization_id", organizationId).eq("user_id", user.id).maybeSingle();
  if (inviterError || !inviter || !["owner", "admin"].includes(inviter.role)) {
    return respond({ error: "Only organization owners and admins can send invitations." }, 403);
  }
  if (role === "client") {
    if (!customerId) return respond({ error: "Choose a customer account for this client." }, 400);
    const { data: customer, error: customerError } = await admin.from("customers")
      .select("id").eq("id", customerId).eq("organization_id", organizationId).maybeSingle();
    if (customerError || !customer) return respond({ error: "The selected customer does not belong to this organization." }, 400);
  } else if (customerId) {
    return respond({ error: "Internal team members cannot be linked to a customer account." }, 400);
  }

  const { data: invitation, error: inviteError } = await admin.auth.admin.inviteUserByEmail(email, {
    redirectTo: allowedOrigin,
    data: { invited_organization_id: organizationId },
  });
  if (inviteError || !invitation?.user) {
    return respond({ error: inviteError?.message || "The invitation email could not be sent." }, 400);
  }

  const { error: membershipError } = await admin.from("organization_members").insert({
    organization_id: organizationId, user_id: invitation.user.id, role, customer_id: customerId,
  });
  if (membershipError) {
    return respond({ error: "The invite email was sent, but account access could not be assigned. Please contact support before sending another invitation." }, 500);
  }
  return respond({ ok: true });
});
