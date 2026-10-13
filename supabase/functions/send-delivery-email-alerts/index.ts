import { createClient } from "npm:@supabase/supabase-js@2";

const allowedOrigin = "https://logisstant.vercel.app";
const corsHeaders = {
  "Access-Control-Allow-Origin": allowedOrigin,
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};
const json = (body: Record<string, unknown>, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: corsHeaders });

function escapeHtml(value: unknown) {
  return String(value ?? "").replace(/[&<>"']/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char]!);
}
function dayDifference(eta: string, today: string) {
  return Math.round((Date.parse(eta + "T00:00:00Z") - Date.parse(today + "T00:00:00Z")) / 86400000);
}
Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed." }, 405);
  if (req.headers.get("origin") && req.headers.get("origin") !== allowedOrigin) return json({ error: "Origin not allowed." }, 403);
  let body: { action?: string; organization_id?: string };
  try { body = await req.json(); } catch { return json({ error: "Invalid request." }, 400); }
  const url = Deno.env.get("SUPABASE_URL"), serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const resendKey = Deno.env.get("RESEND_API_KEY"), from = Deno.env.get("RESEND_FROM_EMAIL") || "Logisstant <onboarding@resend.dev>";
  if (!url || !serviceKey || !resendKey) return json({ error: "Email delivery is not configured." }, 503);
  const db = createClient(url, serviceKey, { auth: { autoRefreshToken: false, persistSession: false } });
  if (body.action === "test") {
    const authorization = req.headers.get("Authorization") || "";
    const token = authorization.toLowerCase().startsWith("bearer ") ? authorization.slice(7).trim() : "";
    if (!token || !body.organization_id) return json({ error: "Sign in as an organization admin to send a test." }, 401);
    const { data: authData, error: authError } = await db.auth.getUser(token);
    const user = authData?.user;
    if (authError || !user) return json({ error: "Sign in as an organization admin to send a test." }, 401);
    const { data: member } = await db.from("organization_members").select("role").eq("organization_id", body.organization_id).eq("user_id", user.id).maybeSingle();
    if (!member || !["owner", "admin"].includes(member.role)) return json({ error: "Only organization owners and admins can send a test." }, 403);
    const response = await fetch("https://api.resend.com/emails", {
      method: "POST", headers: { "Authorization": "Bearer " + resendKey, "Content-Type": "application/json" },
      body: JSON.stringify({ from, to: ["delivered@resend.dev"], subject: "Logisstant test e-postası", html: "<div style=\"font-family:Arial,sans-serif\"><h2>Logisstant e-posta bağlantısı hazır</h2><p>Bu, Resend\u0027in test adresine gönderilen deneme mesajıdır. Gerçek bir müşteri posta kutusuna gönderilmemiştir.</p></div>" }),
    });
    if (!response.ok) return json({ error: "Resend test gönderimi başarısız oldu. API anahtarını ve gönderen adresini kontrol edin." }, 502);
    return json({ ok: true, simulated: true });
  }
  const expected = Deno.env.get("DELIVERY_ALERT_CRON_SECRET");
  const provided = req.headers.get("x-cron-secret") || "";
  if (!expected || provided.length !== expected.length || !crypto.subtle) return json({ error: "Unauthorized." }, 401);
  const a = new TextEncoder().encode(provided), b = new TextEncoder().encode(expected);
  const digestA = new Uint8Array(await crypto.subtle.digest("SHA-256", a));
  const digestB = new Uint8Array(await crypto.subtle.digest("SHA-256", b));
  let mismatch = 0; for (let i = 0; i < digestA.length; i++) mismatch |= digestA[i] ^ digestB[i];
  if (mismatch !== 0) return json({ error: "Unauthorized." }, 401);
  const today = new Date().toISOString().slice(0, 10);
  const { data: preferences, error: prefError } = await db.from("notification_preferences")
    .select("organization_id, user_id").eq("email_delivery_alerts", true);
  if (prefError) return json({ error: "Could not load notification preferences." }, 500);
  const { data: shipments, error: shipmentError } = await db.from("shipments")
    .select("id, organization_id, customer_id, code, route, status, eta, customers(name)")
    .not("eta", "is", null);
  if (shipmentError) return json({ error: "Could not load shipment dates." }, 500);

  let sent = 0, skipped = 0, failed = 0;
  for (const preference of preferences || []) {
    const [{ data: membership }, { data: authUser }] = await Promise.all([
      db.from("organization_members").select("role, customer_id").eq("organization_id", preference.organization_id).eq("user_id", preference.user_id).maybeSingle(),
      db.auth.admin.getUserById(preference.user_id),
    ]);
    if (!membership || !authUser?.user?.email) { skipped++; continue; }
    const visibleShipments = (shipments || []).filter((item) =>
      item.organization_id === preference.organization_id &&
      item.status !== "Teslim Edildi" && item.status !== "Delivered" &&
      (membership.role !== "client" || item.customer_id === membership.customer_id)
    );
    for (const shipment of visibleShipments) {
      if (!shipment.eta) continue;
      const days = dayDifference(shipment.eta, today);
      const type = days < 0 ? "overdue" : days <= 3 ? "upcoming" : null;
      if (!type) continue;
      const { data: prior } = await db.from("email_delivery_alert_log").select("sent_at")
        .eq("user_id", preference.user_id).eq("shipment_id", shipment.id).eq("alert_type", type).eq("eta_date", shipment.eta).maybeSingle();
      if (prior) { skipped++; continue; }
      const code = escapeHtml(shipment.code), route = escapeHtml(shipment.route), customer = escapeHtml(shipment.customers?.name || "");
      const timingTr = days < 0 ? "planlanan teslim tarihi geçti" : days === 0 ? "teslimat bugün bekleniyor" : `${days} gün içinde teslimat bekleniyor`;
      const timingEn = days < 0 ? "the expected delivery date has passed" : days === 0 ? "delivery is expected today" : `delivery is expected in ${days} days`;
      const response = await fetch("https://api.resend.com/emails", {
        method: "POST", headers: { "Authorization": `Bearer ${resendKey}`, "Content-Type": "application/json" },
        body: JSON.stringify({
          from, to: [authUser.user.email], subject: `Logisstant · ${shipment.code} teslimat hatırlatması`,
          html: `<div style="font-family:Arial,sans-serif;max-width:600px;margin:auto;color:#172554"><h2>Logisstant teslimat hatırlatması</h2><p><strong>${code}</strong> numaralı sevkiyat için ${timingTr}.</p><p>Güzergâh: ${route}<br>Müşteri: ${customer}<br>Planlanan teslim: ${escapeHtml(shipment.eta)}</p><hr><p style="color:#475569">Delivery reminder for shipment <strong>${code}</strong>: ${timingEn}.</p><p>Route: ${route}<br>Customer: ${customer}<br>Expected delivery: ${escapeHtml(shipment.eta)}</p><p><a href="https://logisstant.vercel.app/">Logisstant uygulamasını aç</a></p></div>`,
        }),
      });
      if (!response.ok) { failed++; continue; }
      const { error: logError } = await db.from("email_delivery_alert_log").insert({
        organization_id: preference.organization_id, user_id: preference.user_id, shipment_id: shipment.id, alert_type: type, eta_date: shipment.eta,
      });
      if (logError) failed++; else sent++;
    }
  }
  return json({ ok: failed === 0, sent, skipped, failed, date: today });
});