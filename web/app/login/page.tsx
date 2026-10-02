import type { Metadata } from "next";
import { notFound, redirect } from "next/navigation";

import { AuthCard } from "@/components/AuthCard";
import { errorMessage, noticeMessage, param } from "@/lib/accounts/messages";
import { viewerMode } from "@/lib/mode";
import { currentSession, safeReturnPath } from "@/lib/viewer";

// Sign in (accounts mode only). The form posts to /api/auth/login, which
// answers with a redirect: back here with an error code, or on to `next`.
export const dynamic = "force-dynamic";
export const metadata: Metadata = { title: "Sign in — PulsHealth" };

type Search = Promise<Record<string, string | string[] | undefined>>;

export default async function LoginPage({ searchParams }: { searchParams: Search }) {
  if (viewerMode() !== "accounts") notFound();
  const params = await searchParams;
  const next = safeReturnPath(param(params.next));

  // Already signed in: nothing to do here. A database that cannot be reached
  // still gets the form; the sign-in itself then says so.
  const session = await currentSession().catch(() => null);
  if (session) redirect(next);

  return (
    <AuthCard
      title="Sign in"
      subtitle="Your health records, from your own devices."
      error={errorMessage(param(params.error))}
      notice={noticeMessage(param(params.notice))}
    >
      <form method="post" action="/api/auth/login">
        <input type="hidden" name="next" value={next} />
        <div className="form-field">
          <label htmlFor="email">Email</label>
          <input id="email" name="email" type="email" autoComplete="username" required autoFocus />
        </div>
        <div className="form-field">
          <label htmlFor="password">Password</label>
          <input id="password" name="password" type="password" autoComplete="current-password" required />
        </div>
        <button type="submit" className="btn btn-primary btn-block" style={{ marginTop: 6 }}>
          Sign in
        </button>
      </form>
      <p className="form-hint" style={{ margin: "18px 0 0", lineHeight: 1.5 }}>
        Accounts are by invitation. To join, or if you have forgotten your password, ask the person who runs
        this viewer for an invite link.
      </p>
    </AuthCard>
  );
}
