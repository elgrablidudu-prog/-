-- Migration 119: backfill owner_trial14_notified_at for tenants that already
-- existed before migration 118 introduced the real send logic.
--
-- Migration 118 renamed owner_trial20_notified_at -> owner_trial14_notified_at
-- but did not backfill it (unlike owner_new_tenant_notified_at, which
-- migration 110 did backfill for pre-existing tenants). The result: the first
-- real run of check_and_notify_trial14() found old tenants that legitimately
-- matched the 14-day + activity condition and had never been flagged, and
-- sent a one-time "catch-up" email for them (e.g. a family/test trial tenant
-- created back in June) — surprising, not a bug, but not what the owner
-- wants going forward.
--
-- Same backfill pattern as migration 110: mark every tenant that exists
-- today as already notified, so from here on only genuinely new signups
-- (and tenants that cross 14 days AFTER today) trigger an email.
UPDATE tenants SET owner_trial14_notified_at = now()
WHERE owner_trial14_notified_at IS NULL;
