// Which kind of access control this viewer runs, decided from the environment
// on every call (one published image serves all three: edit .env,
// `docker compose up -d web`).
//
//   accounts  WEB_ACCOUNTS=true. People sign in with their own email and
//             password and see only their own records; the viewer connects
//             as the web_app role, which the database scopes per user
//             (server/db/migrations/015_web_accounts.sql). Needs HTTPS.
//   basic     WEB_AUTH_PASSWORD set. One shared password over HTTP Basic, any
//             user selectable (lib/auth.ts). Unchanged from before accounts.
//   open      Neither. No login at all; the bind address is the only guard.
//
// Accounts mode wins when both are set: the shared password would otherwise
// sit in front of a login that already identifies the person.

export type ViewerMode = "accounts" | "basic" | "open";

/** The environment, or a stand-in for it in tests. */
export type Env = Record<string, string | undefined>;

/** An environment flag that is on: true/1/yes/on, any case. */
export function isTrue(value: string | undefined): boolean {
  return /^(true|1|yes|on)$/i.test((value ?? "").trim());
}

export function viewerMode(env: Env = process.env): ViewerMode {
  if (isTrue(env.WEB_ACCOUNTS)) return "accounts";
  if (env.WEB_AUTH_PASSWORD) return "basic";
  return "open";
}

/**
 * Whether X-Forwarded-* and CF-Connecting-IP may be believed. Same switch,
 * same default and same caveat as ingest and the product API: only when a
 * proxy that overwrites those headers is the ONLY way to reach the port.
 */
export function trustProxyHeaders(env: Env = process.env): boolean {
  return isTrue(env.TRUST_PROXY_HEADERS);
}
