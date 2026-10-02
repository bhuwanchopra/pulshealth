// Thin Postgres access. Server-only — never import from a client component.
import { Pool, type PoolClient } from "pg";

let pool: Pool | null = null;
let initialized = false;

export function getPool(): Pool | null {
  if (!process.env.DATABASE_URL) return null;
  if (!initialized) {
    initialized = true;
    pool = new Pool({
      connectionString: process.env.DATABASE_URL,
      max: 4,
      connectionTimeoutMillis: 4000,
      idleTimeoutMillis: 10_000,
      // Don't let a heavy ad-hoc query wedge a request.
      statement_timeout: 20_000,
      query_timeout: 22_000,
    });
    // Swallow background idle-client errors so they don't crash the process.
    pool.on("error", () => {});
  }
  return pool;
}

/** Runs one statement on whichever pooled connection is free. */
export type QueryFn = <T = Record<string, unknown>>(text: string, params?: unknown[]) => Promise<T[]>;

/**
 * One statement outside any user scope. For what is not anyone's health
 * data: the health check, the database's time zone, and Basic mode's list
 * of users. Health data goes through `scoped`.
 */
export const query: QueryFn = async <T = Record<string, unknown>>(text: string, params: unknown[] = []) => {
  const p = getPool();
  if (!p) throw new Error("DATABASE_URL not configured");
  const res = await p.query(text, params);
  return res.rows as T[];
};

// Any canonical UUID. Deliberately looser than config's v1–v5 check: this
// only has to keep the value a valid uuid for the setting's cast, and ids
// arrive from phones the viewer did not mint.
const UUID_SHAPE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * Runs `fn` in one read-only transaction on one connection, with
 * `puls.user_id` set to `userId` for that transaction only.
 *
 * As the `web_app` role (accounts mode) that setting is what the database
 * filters every health relation on (server/db/migrations/015_web_accounts.sql):
 * the query sees `userId`'s rows and nobody else's, whatever its own WHERE
 * clause says. As `grafana` (Basic mode) the setting is inert and the
 * queries' own `user_id = $n` filters do the work, exactly as before.
 *
 * `fn` must issue its statements through `q` only. Calling `query()` or a
 * nested `scoped()` from inside would check out a second connection while
 * this one is held, and a handful of concurrent requests doing that can
 * exhaust the pool and wait on each other until the connection timeout.
 */
export async function scoped<T>(userId: string, fn: (q: QueryFn) => Promise<T>): Promise<T> {
  if (!UUID_SHAPE.test(userId)) throw new Error("scoped(): the user id must be a UUID");
  // `true`: local to this transaction. COMMIT or ROLLBACK clears it, so a
  // pooled connection never carries one request's user into the next.
  return inTransaction("BEGIN READ ONLY", [["SELECT set_config('puls.user_id', $1, true)", [userId]]], fn);
}

/**
 * Runs `fn` in one read-write transaction with no user scope. For the
 * viewer's own account store (schema auth) only — health data is read
 * through `scoped`, and web_app cannot write it at all. The same rule about
 * issuing statements through `q` only applies.
 */
export async function transaction<T>(fn: (q: QueryFn) => Promise<T>): Promise<T> {
  return inTransaction("BEGIN", [], fn);
}

async function inTransaction<T>(
  begin: string,
  setup: [string, unknown[]][],
  fn: (q: QueryFn) => Promise<T>,
): Promise<T> {
  const p = getPool();
  if (!p) throw new Error("DATABASE_URL not configured");

  const client: PoolClient = await p.connect();
  // A connection whose transaction state is unknown must not go back to the
  // pool, or the next request would inherit it (and any user setting).
  let discard: Error | undefined;
  try {
    await client.query(begin);
    for (const [text, params] of setup) await client.query(text, params);
    const q: QueryFn = async <R = Record<string, unknown>>(text: string, params: unknown[] = []) => {
      const res = await client.query(text, params);
      return res.rows as R[];
    };
    const result = await fn(q);
    await client.query("COMMIT");
    return result;
  } catch (e) {
    try {
      await client.query("ROLLBACK");
    } catch (rollbackError) {
      discard = rollbackError instanceof Error ? rollbackError : new Error(String(rollbackError));
    }
    throw e;
  } finally {
    client.release(discard);
  }
}
