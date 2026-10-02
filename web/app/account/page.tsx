import type { Metadata } from "next";
import { notFound, redirect } from "next/navigation";

import { PageHeader } from "@/components/PageHeader";
import { errorMessage, noticeMessage, param } from "@/lib/accounts/messages";
import { PASSWORD_MIN_LENGTH } from "@/lib/accounts/password";
import { listSessions } from "@/lib/accounts/session";
import { formatFull } from "@/lib/format";
import { viewerMode } from "@/lib/mode";
import { currentSession } from "@/lib/viewer";

// The signed-in person's own account (accounts mode only): change the
// password, see where the account is signed in and sign those browsers out.
// The forms post to /api/auth/password and /api/auth/sessions.
export const dynamic = "force-dynamic";
export const metadata: Metadata = { title: "Account — PulsHealth" };

type Search = Promise<Record<string, string | string[] | undefined>>;

export default async function AccountPage({ searchParams }: { searchParams: Search }) {
  if (viewerMode() !== "accounts") notFound();
  const session = await currentSession();
  if (!session) redirect("/login?next=%2Faccount");
  const search = await searchParams;
  const sessions = await listSessions(session.accountId, session.id);
  const error = errorMessage(param(search.error));
  const notice = noticeMessage(param(search.notice));

  return (
    <>
      <PageHeader eyebrow="Account" title="Account" subtitle={`Signed in as ${session.email}.`} />

      {error && (
        <div className="form-message error" role="alert" style={{ maxWidth: 560 }}>
          {error}
        </div>
      )}
      {notice && (
        <div className="form-message notice" role="status" style={{ maxWidth: 560 }}>
          {notice}
        </div>
      )}

      <section className="rise" style={{ marginTop: 8 }}>
        <div className="eyebrow" style={{ marginBottom: 12 }}>Password</div>
        <form method="post" action="/api/auth/password" className="panel" style={{ padding: "20px 20px 6px", maxWidth: 560 }}>
          <input type="text" name="username" value={session.email} autoComplete="username" readOnly hidden />
          <div className="form-field">
            <label htmlFor="current">Current password</label>
            <input id="current" name="current" type="password" autoComplete="current-password" required />
          </div>
          <div className="form-field">
            <label htmlFor="password">New password</label>
            <input id="password" name="password" type="password" autoComplete="new-password" minLength={PASSWORD_MIN_LENGTH} required />
            <span className="form-hint">At least {PASSWORD_MIN_LENGTH} characters. Changing it signs out every other browser.</span>
          </div>
          <div className="form-field">
            <label htmlFor="confirm">Repeat the new password</label>
            <input id="confirm" name="confirm" type="password" autoComplete="new-password" minLength={PASSWORD_MIN_LENGTH} required />
          </div>
          <div style={{ marginBottom: 14 }}>
            <button type="submit" className="btn btn-primary">Change password</button>
          </div>
        </form>
      </section>

      <section className="rise" style={{ marginTop: 28 }}>
        <div className="eyebrow" style={{ marginBottom: 12 }}>Signed in</div>
        <div className="panel" style={{ maxWidth: 720 }}>
          {sessions.map((s) => (
            <div key={s.id} className="session-row">
              <div style={{ minWidth: 0 }}>
                <div style={{ fontSize: 14, fontWeight: 550 }}>
                  {describeAgent(s.userAgent)}
                  {s.current && <span className="chip" style={{ marginLeft: 8 }}>This browser</span>}
                </div>
                <div style={{ fontSize: 12.5, color: "var(--muted)", marginTop: 3 }}>
                  Last active {formatFull(s.lastSeenAt)} · signed in {formatFull(s.createdAt)}
                  {s.ip ? ` · ${s.ip}` : ""}
                </div>
              </div>
              <form method="post" action="/api/auth/sessions">
                <input type="hidden" name="session" value={s.id} />
                <button type="submit" className="btn">{s.current ? "Sign out" : "Sign out this browser"}</button>
              </form>
            </div>
          ))}
        </div>
        {sessions.length > 1 && (
          <form method="post" action="/api/auth/sessions" style={{ marginTop: 14 }}>
            <input type="hidden" name="session" value="others" />
            <button type="submit" className="btn">Sign out everywhere else</button>
          </form>
        )}
      </section>
    </>
  );
}

// "Safari on macOS", "Chrome on Android", … from a User-Agent; good enough to
// tell your own browsers apart, never used for anything else.
function describeAgent(agent: string | null): string {
  if (!agent) return "Unknown browser";
  const browser = /Edg\//.test(agent)
    ? "Edge"
    : /Firefox\//.test(agent)
      ? "Firefox"
      : /Chrome\//.test(agent)
        ? "Chrome"
        : /Safari\//.test(agent)
          ? "Safari"
          : "Browser";
  const os = /iPhone|iPad/.test(agent)
    ? "iOS"
    : /Android/.test(agent)
      ? "Android"
      : /Mac OS X/.test(agent)
        ? "macOS"
        : /Windows/.test(agent)
          ? "Windows"
          : /Linux/.test(agent)
            ? "Linux"
            : null;
  return os ? `${browser} on ${os}` : browser;
}
