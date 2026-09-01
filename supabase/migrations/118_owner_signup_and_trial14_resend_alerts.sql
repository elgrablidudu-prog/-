-- Migration 118: real email alerts to the owner via Resend — replaces the
-- dead automation described in migration 110 (that migration only added the
-- bookkeeping columns; the daily check that was supposed to read them was a
-- scheduled Claude session that no longer exists, and it only ever posted a
-- chat message, never a real email).
--
-- Two triggers, both one-shot per tenant (never repeats):
--   1. A new tenant signs up               -> immediate email.
--   2. A tenant crosses 14 days since       -> email reminding to set up the
--      signup AND has real activity            Grow/PayMe checkout links
--      (at least one lead created)             (owner_trial14_notified_at
--                                                replaces the old 20/30-day
--                                                owner_trial20_notified_at;
--                                                the business rule is 14
--                                                days, not 20 of 30).
--
-- Delivery is a direct call to the Resend API via pg_net (same net.http_post
-- mechanism already used by send_daily_lead_digest in 066/111) — no new
-- Edge Function, no Make.com webhook. Requires a Resend API key stored in
-- Supabase Vault under the name 'resend_api_key' (see bottom of this file
-- for the one-time manual step; this migration cannot create the secret
-- itself).

-- ── 1. Rename the mis-scoped column (20/30 days -> 14 days) ────────────────
ALTER TABLE tenants RENAME COLUMN owner_trial20_notified_at TO owner_trial14_notified_at;

-- ── 2. Shared send helper ───────────────────────────────────────────────────
-- Fire-and-forget: pg_net queues the HTTP request asynchronously, so a Resend
-- outage or a missing/invalid API key never blocks the tenant signup insert
-- or the daily cron run. Errors are swallowed on purpose (best-effort alert,
-- not a business-critical path).
CREATE OR REPLACE FUNCTION public._notify_owner_email(p_subject text, p_html text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_api_key text;
BEGIN
  SELECT decrypted_secret INTO v_api_key
  FROM vault.decrypted_secrets WHERE name = 'resend_api_key';

  IF v_api_key IS NULL THEN
    RETURN; -- secret not configured yet, no-op
  END IF;

  PERFORM net.http_post(
    url     := 'https://api.resend.com/emails',
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer ' || v_api_key
    ),
    body    := jsonb_build_object(
      'from',    'PLTO <onboarding@resend.dev>',
      'to',      jsonb_build_array('elgrablidudu@gmail.com'),
      'subject', p_subject,
      'html',    p_html
    )
  );
EXCEPTION WHEN OTHERS THEN
  NULL; -- never let a notification failure break the caller
END;
$fn$;

REVOKE EXECUTE ON FUNCTION public._notify_owner_email(text, text) FROM PUBLIC, anon, authenticated;

-- ── 3. New signup -> immediate email ────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._notify_owner_new_tenant()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
BEGIN
  PERFORM public._notify_owner_email(
    'נרשם עסק חדש ל-PLTO: ' || coalesce(NEW.name, NEW.slug),
    '<p>נפתח חשבון חדש במערכת.</p>'
    || '<p><b>שם:</b> ' || coalesce(NEW.name, '—') || '</p>'
    || '<p><b>תחום:</b> ' || coalesce(NEW.industry, '—') || '</p>'
    || '<p><b>אימייל:</b> ' || coalesce(NEW.billing_email, '—') || '</p>'
    || '<p><b>נרשם ב:</b> ' || to_char(NEW.created_at AT TIME ZONE 'Asia/Jerusalem', 'DD/MM/YYYY HH24:MI') || '</p>'
  );
  NEW.owner_new_tenant_notified_at := now();
  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS trg_notify_owner_new_tenant ON tenants;
CREATE TRIGGER trg_notify_owner_new_tenant
  BEFORE INSERT ON tenants
  FOR EACH ROW EXECUTE FUNCTION public._notify_owner_new_tenant();

-- ── 4. Daily check: 14 days since signup + real activity -> email ──────────
CREATE OR REPLACE FUNCTION public.check_and_notify_trial14()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT t.id, t.name, t.slug, t.billing_email, t.industry, t.created_at
    FROM tenants t
    WHERE t.owner_trial14_notified_at IS NULL
      AND t.created_at <= now() - interval '14 days'
      AND EXISTS (SELECT 1 FROM leads l WHERE l.tenant_id = t.id)
  LOOP
    PERFORM public._notify_owner_email(
      'עסק פעיל 14 יום ב-PLTO: ' || coalesce(r.name, r.slug) || ' — זמן לחבר סליקה',
      '<p>הטננט הבא עובר 14 יום מההרשמה ויש לו פעילות אמיתית (לפחות ליד אחד).</p>'
      || '<p><b>שם:</b> ' || coalesce(r.name, '—') || '</p>'
      || '<p><b>תחום:</b> ' || coalesce(r.industry, '—') || '</p>'
      || '<p><b>אימייל:</b> ' || coalesce(r.billing_email, '—') || '</p>'
      || '<p><b>נרשם ב:</b> ' || to_char(r.created_at AT TIME ZONE 'Asia/Jerusalem', 'DD/MM/YYYY') || '</p>'
      || '<p>מומלץ לוודא שקישורי הסליקה של Grow/PayMe מוכנים לחבילה שלו.</p>'
    );
    UPDATE tenants SET owner_trial14_notified_at = now() WHERE id = r.id;
  END LOOP;
END;
$fn$;

REVOKE EXECUTE ON FUNCTION public.check_and_notify_trial14() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.check_and_notify_trial14() TO postgres;

DO $$ BEGIN
  PERFORM cron.unschedule('owner-trial14-check');
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

-- 06:00 UTC = 09:00 שעון ישראל (חורף) / 08:00 בקיץ — פעם ביום מספיק, זה לא זמן-אמת
SELECT cron.schedule(
  'owner-trial14-check',
  '0 6 * * *',
  $$SELECT public.check_and_notify_trial14()$$
);

-- ── שלב ידני חד-פעמי (לא מתבצע ע"י המיגרציה הזו) ──────────────────────────
-- יש להריץ ב-SQL Editor של הפרויקט, עם מפתח ה-API האמיתי מ-Resend:
--   select vault.create_secret('re_xxxxxxxxxxxxxxxx', 'resend_api_key');
-- בלי זה, שתי הפונקציות למעלה פשוט לא שולחות כלום (no-op), לא נכשלות.
--
-- הערה על כתובת השולח: 'onboarding@resend.dev' היא כתובת הבדיקה של Resend,
-- שיכולה לשלוח רק לכתובת המייל של בעל חשבון ה-Resend עצמו. לשליחה אמינה
-- וללא ההגבלה הזו, יש לאמת דומיין אמיתי (למשל plto.app) בחשבון ה-Resend
-- ולעדכן את כתובת ה-from כאן בהתאם.
