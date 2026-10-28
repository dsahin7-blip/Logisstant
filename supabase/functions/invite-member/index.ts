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

async function findAuthUserByEmail(admin: ReturnType<typeof createClient>, email: string) {
  const perPage = 1000;
  for (let page = 1; page <= 1000; page++) {
    const { data, error } = await admin.auth.admin.listUsers({ page, perPage });
    if (error) throw error;
    const user = (data.users || []).find((candidate) => candidate.email?.toLowerCase() === email);
    if (user) return user;
    if (!data.users || data.users.length < perPage) return null;
  }
  return null;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return respond({ error: "Method not allowed." }, 405);
  if (req.headers.get("origin") && req.headers.get("origin") !== allowedOrigin) {
    return respond({ error: "Origin not allowed." }, 403);
  }

  const authorization = req.headers.get("Authorization") || "";
  const token = authorization.toLowerCase().startsWith("bearer ") ? authorization.slice(7).trim() : authorization.trim();
  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
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
  const emailParts = email.split("@");
  if (!organizationId || emailParts.length !== 2 || !emailParts[0] || !emailParts[1]?.includes(".") || email.includes(" ") || !["operations", "finance", "client"].includes(role || "")) {
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

  let invitee: { id: string; email?: string } | null = null;
  let existingAccount = false;
  const redirectTo = allowedOrigin + "?workspace=" + encodeURIComponent(organizationId);
  const { data: invitation, error: inviteError } = await admin.auth.admin.inviteUserByEmail(email, {
    redirectTo,
    data: { invited_organization_id: organizationId },
  });

  if (invitation?.user) {
    invitee = invitation.user;
  } else if (inviteError && /already.*(registered|exist)|user.*already|already.*email/i.test(inviteError.message)) {
    try {
      invitee = await findAuthUserByEmail(admin, email);
    } catch (error) {
      return respond({ error: "Could not look up the existing account. Please try again.", message: error instanceof Error ? error.message : String(error) }, 500);
    }
    if (!invitee) return respond({ error: inviteError.message || "The existing account could not be found." }, 400);
    existingAccount = true;
  } else {
    return respond({ error: inviteError?.message || "The invitation email could not be sent." }, 400);
  }

  const { data: currentMembership, error: currentMembershipError } = await admin.from("organization_members")
    .select("role, customer_id").eq("organization_id", organizationId).eq("user_id", invitee.id).maybeSingle();
  if (currentMembershipError) return respond({ error: "Could not check existing firm access." }, 500);
  if (currentMembership) {
    if (currentMembership.role !== role || currentMembership.customer_id !== customerId) {
      return respond({ error: "This account already has different access in this firm. Update its existing role from the team list instead of sending another invitation." }, 409);
    }
  } else {
    const { error: membershipError } = await admin.from("organization_members").insert({
      organization_id: organizationId, user_id: invitee.id, role, customer_id: customerId,
    });
    if (membershipError) {
      return respond({ error: "The invitation was created, but firm access could not be assigned. Please refresh the team list before trying again." }, 500);
    }
  }

  if (existingAccount) {
    if (!anonKey) return respond({ error: "The customer was linked, but the sign-in email service is not configured. They can sign in with their existing password." }, 500);
    const mailer = createClient(url, anonKey, { auth: { autoRefreshToken: false, persistSession: false, detectSessionInUrl: false } });
    const { error: emailError } = await mailer.auth.signInWithOtp({
      email,
      options: { shouldCreateUser: false, emailRedirectTo: redirectTo },
    });
    if (emailError) {
      return respond({ error: "The customer was linked, but the sign-in email could not be sent. They can still sign in with their existing password.", message: emailError.message }, 502);
    }
    return respond({ ok: true, existingAccount: true, alreadyLinked: Boolean(currentMembership) });
  }

  return respond({ ok: true, existingAccount: false });
});