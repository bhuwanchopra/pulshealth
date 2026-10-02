// The account rows behind accounts mode (schema auth, 015_web_accounts.sql).
// Account identity lives here and never in `users`, whose name and email are
// the phone's HealthKit profile. Server-only.

import { query, transaction } from "../db";
import { tokenHash } from "./session";

/**
 * The stored form of an email address: trimmed and lower-cased (the table's
 * CHECK insists), or null for something that is not plausibly one.
 */
export function normalizeEmail(raw: string | null | undefined): string | null {
  const email = (raw ?? "").trim().toLowerCase();
  if (email.length < 3 || email.length > 254) return null;
  if (!/^[^\s@]+@[^\s@]+$/.test(email)) return null;
  return email;
}

export interface LoginAccount {
  id: string;
  userId: string;
  passwordHash: string;
}

/** The account an email signs in, if it can sign in at all. */
export async function findAccountForLogin(email: string): Promise<LoginAccount | null> {
  const rows = await query<{ id: string; user_id: string; password_hash: string }>(
    `SELECT id::text, user_id::text, password_hash
       FROM auth.accounts
      WHERE email = $1 AND disabled_at IS NULL AND password_hash IS NOT NULL`,
    [email],
  );
  const row = rows[0];
  return row ? { id: row.id, userId: row.user_id, passwordHash: row.password_hash } : null;
}

export async function findPasswordHash(accountId: string): Promise<string | null> {
  const rows = await query<{ password_hash: string | null }>(
    "SELECT password_hash FROM auth.accounts WHERE id = $1 AND disabled_at IS NULL",
    [accountId],
  );
  return rows[0]?.password_hash ?? null;
}

/** Stores a re-hash with current parameters (same password, no sign-out). */
export async function replacePasswordHash(accountId: string, hash: string): Promise<void> {
  await query("UPDATE auth.accounts SET password_hash = $2 WHERE id = $1", [accountId, hash]);
}

/**
 * A new password: stored, and every session of the account ended — the
 * caller's too, which it replaces with a fresh one, so no copy of any cookie
 * survives a password change.
 */
export async function changePassword(accountId: string, hash: string): Promise<void> {
  await transaction(async (q) => {
    await q("UPDATE auth.accounts SET password_hash = $2, password_changed_at = now() WHERE id = $1", [accountId, hash]);
    await q("DELETE FROM auth.sessions WHERE account_id = $1", [accountId]);
  });
}

export interface PendingInvite {
  email: string;
  /** Whether accepting it resets an existing account's password. */
  resetsExisting: boolean;
  expiresAt: number;
}

/** The unused, unexpired invite a link's token names, or null. */
export async function findInvite(token: string): Promise<PendingInvite | null> {
  const hash = tokenHash(token);
  if (!hash) return null;
  const rows = await query<{ email: string; existing: boolean; expires_at: Date }>(
    `SELECT i.email,
            EXISTS (SELECT 1 FROM auth.accounts a WHERE a.user_id = i.user_id) AS existing,
            i.expires_at
       FROM auth.invites i
      WHERE i.token_hash = $1 AND i.accepted_at IS NULL AND i.expires_at > now()`,
    [hash],
  );
  const row = rows[0];
  return row ? { email: row.email, resetsExisting: row.existing, expiresAt: row.expires_at.getTime() } : null;
}

export type AcceptInviteResult = { ok: true; accountId: string } | { ok: false; reason: "invalid" | "email_taken" };

/**
 * Uses an invite: creates the user's account with this password or, when the
 * user already has one, resets it (signing out all of its sessions). An
 * account disabled after the invite was issued stays disabled — the invite
 * reads as spent — while a newer invite re-enables it: disabling (by hand,
 * `UPDATE auth.accounts SET disabled_at = now()`) must not be undone by a
 * link that was already out. The invite is spent, and any other outstanding
 * invite for the same user is withdrawn. One transaction; the invite row is
 * locked, so a link pressed twice is used once.
 */
export async function acceptInvite(token: string, passwordHash: string): Promise<AcceptInviteResult> {
  const hash = tokenHash(token);
  if (!hash) return { ok: false, reason: "invalid" };
  return transaction(async (q) => {
    const invites = await q<{ id: string; user_id: string; email: string; is_admin: boolean; created_at: Date }>(
      `SELECT id::text, user_id::text, email, is_admin, created_at
         FROM auth.invites
        WHERE token_hash = $1 AND accepted_at IS NULL AND expires_at > now()
        FOR UPDATE`,
      [hash],
    );
    const invite = invites[0];
    if (!invite) return { ok: false, reason: "invalid" } as const;

    const taken = await q<{ user_id: string }>(
      "SELECT user_id::text FROM auth.accounts WHERE email = $1 AND user_id <> $2",
      [invite.email, invite.user_id],
    );
    if (taken.length) return { ok: false, reason: "email_taken" } as const;

    const existing = await q<{ id: string; disabled_since_invite: boolean }>(
      `SELECT id::text, disabled_at IS NOT NULL AND disabled_at >= $2 AS disabled_since_invite
         FROM auth.accounts WHERE user_id = $1 FOR UPDATE`,
      [invite.user_id, invite.created_at],
    );
    if (existing[0]?.disabled_since_invite) return { ok: false, reason: "invalid" } as const;
    let accountId: string;
    if (existing[0]) {
      accountId = existing[0].id;
      await q(
        `UPDATE auth.accounts
            SET email = $2, password_hash = $3, password_changed_at = now(),
                is_admin = is_admin OR $4, disabled_at = NULL
          WHERE id = $1`,
        [accountId, invite.email, passwordHash, invite.is_admin],
      );
      await q("DELETE FROM auth.sessions WHERE account_id = $1", [accountId]);
    } else {
      const created = await q<{ id: string }>(
        `INSERT INTO auth.accounts (user_id, email, password_hash, is_admin, password_changed_at)
         VALUES ($1, $2, $3, $4, now())
         RETURNING id::text`,
        [invite.user_id, invite.email, passwordHash, invite.is_admin],
      );
      accountId = created[0].id;
    }
    await q("UPDATE auth.invites SET accepted_at = now() WHERE id = $1", [invite.id]);
    await q(
      `UPDATE auth.invites SET expires_at = now()
        WHERE user_id = $1 AND accepted_at IS NULL AND id <> $2 AND expires_at > now()`,
      [invite.user_id, invite.id],
    );
    return { ok: true, accountId } as const;
  });
}
