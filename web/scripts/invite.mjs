#!/usr/bin/env node
// Issues a one-time invite link for the web viewer's accounts mode.
//
//   docker compose exec web node scripts/invite.mjs --user <uuid> --email <address> [--admin]
//                                                   [--url https://<viewer host>] [--hours 48]
//   make web-invite ARGS='--user <uuid> --email <address> [--admin]'
//
// The person opens the link, chooses a password and is signed in. If the user
// already has an account, the link resets its password (and signs it out
// everywhere) instead — the way back in for a forgotten password, since the
// viewer sends no email. The first administrator is invited the same way,
// with --admin.
//
// The user must already exist in the database: issue the person's device
// token first (`make issue-device NAME=… ARGS='--user <uuid>'`), which
// creates the row, or let their phone sync once. Issuing a device token stays
// a separate step on purpose — the viewer never hands out ingest credentials.
//
// The token is 32 random bytes; only its SHA-256 is stored (auth.invites),
// and the link is printed here once. It works once and expires after
// --hours (48 by default). The base URL comes from --url, else WEB_PUBLIC_URL.
//
// Connects with the container's DATABASE_URL — in accounts mode, the web_app
// role, which may write auth.invites and nothing that holds health data.

import { createHash, randomBytes } from "node:crypto";
import { pathToFileURL } from "node:url";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export const USAGE =
  "usage: node scripts/invite.mjs --user <uuid> --email <address> [--admin] [--url https://<viewer host>] [--hours 48]";

/** Parsed options, or { error } with a message for the operator. */
export function parseArgs(argv, env = {}) {
  const options = { user: null, email: null, admin: false, url: env.WEB_PUBLIC_URL || null, hours: 48 };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const value = () => {
      const next = argv[++i];
      if (next === undefined || next.startsWith("--")) throw new Error(`${arg} needs a value`);
      return next;
    };
    try {
      if (arg === "--user") options.user = value();
      else if (arg === "--email") options.email = value();
      else if (arg === "--url") options.url = value();
      else if (arg === "--hours") options.hours = Number(value());
      else if (arg === "--admin") options.admin = true;
      else if (arg === "--help" || arg === "-h") return { help: true };
      else return { error: `unknown argument: ${arg}` };
    } catch (e) {
      return { error: e.message };
    }
  }
  if (!options.user || !UUID.test(options.user)) return { error: "--user must be the user's UUID" };
  options.user = options.user.toLowerCase();
  const email = normalizeEmail(options.email);
  if (!email) return { error: "--email must be an email address" };
  options.email = email;
  if (!Number.isInteger(options.hours) || options.hours < 1 || options.hours > 24 * 14) {
    return { error: "--hours must be a whole number of hours between 1 and 336" };
  }
  if (options.url) {
    let url;
    try {
      url = new URL(options.url);
    } catch {
      return { error: `not a URL: ${options.url}` };
    }
    if (url.protocol !== "https:" && !["localhost", "127.0.0.1"].includes(url.hostname)) {
      return { error: "the viewer's URL must be https:// — accounts mode refuses plain HTTP" };
    }
    options.url = url.origin;
  }
  return { options };
}

/** Same rule as lib/accounts/store.ts normalizeEmail. */
export function normalizeEmail(raw) {
  const email = String(raw ?? "").trim().toLowerCase();
  if (email.length < 3 || email.length > 254 || !/^[^\s@]+@[^\s@]+$/.test(email)) return null;
  return email;
}

/** A fresh token and the hash that is stored for it. */
export function newInviteToken() {
  const bytes = randomBytes(32);
  return { token: bytes.toString("base64url"), hash: createHash("sha256").update(bytes).digest() };
}

async function main() {
  const parsed = parseArgs(process.argv.slice(2), process.env);
  if (parsed.help) {
    console.log(USAGE);
    return 0;
  }
  if (parsed.error) {
    console.error(`invite: ${parsed.error}\n${USAGE}`);
    return 2;
  }
  const { user, email, admin, url, hours } = parsed.options;
  if (!process.env.DATABASE_URL) {
    console.error("invite: DATABASE_URL is not set (run this inside the web container: docker compose exec web …)");
    return 1;
  }

  const { default: pg } = await import("pg");
  const client = new pg.Client({ connectionString: process.env.DATABASE_URL });
  await client.connect();
  try {
    const taken = await client.query(
      "SELECT user_id::text FROM auth.accounts WHERE email = $1 AND user_id <> $2",
      [email, user],
    );
    if (taken.rowCount) {
      console.error(`invite: ${email} already signs in another user's account (${taken.rows[0].user_id}).`);
      return 1;
    }
    const existing = await client.query("SELECT email FROM auth.accounts WHERE user_id = $1", [user]);
    const { token, hash } = newInviteToken();
    const inserted = await client.query(
      `INSERT INTO auth.invites (token_hash, user_id, email, is_admin, expires_at)
       VALUES ($1, $2, $3, $4, now() + make_interval(hours => $5))
       RETURNING expires_at`,
      [hash, user, email, admin, hours],
    );
    const path = `/invite/${token}`;
    const what = existing.rowCount
      ? `Password reset for ${existing.rows[0].email}'s account (it will sign in as ${email})`
      : `Invite for ${email}`;
    console.log(`${what}${admin ? ", as an administrator" : ""}, user ${user}.`);
    console.log(`Works once, until ${inserted.rows[0].expires_at.toISOString()}. Send it privately:\n`);
    if (url) {
      console.log(`  ${url}${path}\n`);
    } else {
      console.log(`  ${path}\n`);
      console.log("Prefix it with the viewer's https:// address (set WEB_PUBLIC_URL, or pass --url, to have it printed whole).");
    }
    return 0;
  } catch (e) {
    if (e && e.code === "23503") {
      console.error(
        `invite: there is no user ${user} in the database yet. Issue the person's device token first ` +
          "(make issue-device NAME='…' ARGS='--user <uuid>'), which creates the user, or let their phone sync once.",
      );
      return 1;
    }
    if (e && e.code === "42501") {
      console.error("invite: this database role may not write invites. The web container must connect as web_app (accounts mode).");
      return 1;
    }
    if (e && e.code === "3F000") {
      console.error("invite: the database has no `auth` schema yet; run the migrate service (docker compose up -d).");
      return 1;
    }
    throw e;
  } finally {
    await client.end();
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().then(
    (code) => process.exit(code),
    (e) => {
      console.error("invite: failed:", e instanceof Error ? e.message : e);
      process.exit(1);
    },
  );
}
