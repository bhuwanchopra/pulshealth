import type { Metadata, Viewport } from "next";
import { headers } from "next/headers";
import { connection } from "next/server";
import { GeistSans } from "geist/font/sans";
import { GeistMono } from "geist/font/mono";
import "./globals.css";
import { Sidebar } from "@/components/Sidebar";
import { UnitsProvider } from "@/components/UnitsProvider";
import { getDataSource, getUsers } from "@/lib/queries";
import { configuredTimeZone } from "@/lib/config";
import { viewerMode } from "@/lib/mode";
import { currentSession, viewerUser } from "@/lib/viewer";

export const metadata: Metadata = {
  title: "PulsHealth",
  description: "A sleek window into your self-hosted HealthKit data.",
  // Someone's health records: never for a search index, in any mode.
  robots: { index: false, follow: false },
};

export const viewport: Viewport = {
  themeColor: "#08080a",
};

// Set the theme before paint to avoid a flash.
const themeScript = `(()=>{try{var t=localStorage.getItem('puls-theme')||'dark';document.documentElement.dataset.theme=t;}catch(e){document.documentElement.dataset.theme='dark';}})();`;

export default async function RootLayout({ children }: { children: React.ReactNode }) {
  // The data pages are force-dynamic, but the static /_not-found route still
  // prerendered this layout at build time — with no DATABASE_URL in the image
  // builder, that baked a "Database unavailable" chip (and the build-time zone)
  // into every unmatched URL. Defer to request time so the sidebar status is
  // always live.
  await connection();
  // proxy.ts puts a fresh nonce in the Content-Security-Policy; the one inline
  // script here must carry it or the browser refuses to run it.
  const nonce = (await headers()).get("x-nonce") ?? undefined;
  const timeZone = configuredTimeZone();
  const runtimeScript = `window.__PULS_TIME_ZONE__=${JSON.stringify(timeZone).replace(/</g, "\\u003c")};${themeScript}`;
  return (
    <html lang="en" suppressHydrationWarning className={`${GeistSans.variable} ${GeistMono.variable}`}>
      <head>
        <script nonce={nonce} dangerouslySetInnerHTML={{ __html: runtimeScript }} />
      </head>
      <body>
        <div className="app-bg" />
        <div className="grain" />
        <UnitsProvider>{await shell(children)}</UnitsProvider>
      </body>
    </html>
  );
}

// The sidebar and content column, or — in accounts mode, for someone not
// signed in — just the page, centred: the sign-in and invite pages are the
// only ones proxy.ts lets them reach, and a sidebar of links they cannot
// follow would only bounce them back to sign in.
async function shell(children: React.ReactNode) {
  if (viewerMode() === "accounts") {
    // No switcher and no list of users: the session's user is the only one.
    const session = await currentSession().catch(() => null);
    if (!session) return <main className="auth-shell">{children}</main>;
    const source = await getDataSource();
    return (
      <div className="shell">
        <Sidebar source={source} users={[]} currentUserId={session.userId} account={{ email: session.email }} />
        <main className="content">{children}</main>
      </div>
    );
  }
  const [source, users, currentUserId] = await Promise.all([getDataSource(), getUsers(), viewerUser()]);
  return (
    <div className="shell">
      <Sidebar source={source} users={users} currentUserId={currentUserId} />
      <main className="content">{children}</main>
    </div>
  );
}
