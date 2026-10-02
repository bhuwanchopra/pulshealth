import { NextResponse, type NextRequest } from "next/server";

import { UUID_RE } from "@/lib/config";
import { viewerMode } from "@/lib/mode";
import { getDataSource, getUsers } from "@/lib/queries";
import { safeReturnPath, USER_COOKIE, userCookieOptions } from "@/lib/viewer";

// The sidebar's user switcher posts here (SRV-11): a form with `user`, the
// chosen id, and `next`, the page to go back to. The choice is remembered in
// the `puls-user` cookie, which lib/viewer.ts reads on every page. A plain
// form post so the switcher works without JavaScript, and a 303 so the
// browser follows it with a GET.
//
// This is a preference, not access control: proxy.ts already gated the
// request on WEB_AUTH_PASSWORD, and everyone behind that one password may
// look at every user. What is checked is only that the id is a UUID and,
// when the database is reachable, that it names a real row — a typo should
// fail here rather than leave the viewer showing nobody.
export const dynamic = "force-dynamic";

export async function POST(request: NextRequest) {
  // Accounts mode has no switcher: the session decides the user, and this
  // route does not exist.
  if (viewerMode() === "accounts") return new NextResponse("Not found\n", { status: 404, headers: TEXT });
  const form = await request.formData();
  const user = String(form.get("user") ?? "").trim().toLowerCase();
  const next = safeReturnPath(String(form.get("next") ?? ""));

  if (!UUID_RE.test(user)) {
    return new NextResponse("user must be a UUID\n", { status: 400, headers: TEXT });
  }
  if ((await getDataSource()).source === "live") {
    const users = await getUsers();
    if (!users.some((u) => u.id === user)) {
      return new NextResponse("no such user\n", { status: 404, headers: TEXT });
    }
  }

  // A relative Location, so a reverse proxy's internal host never appears in
  // it; `next` is already known to be a same-origin path.
  const response = new NextResponse(null, { status: 303, headers: { Location: next, "Cache-Control": "no-store" } });
  response.cookies.set(USER_COOKIE, user, userCookieOptions(request.nextUrl.protocol === "https:"));
  return response;
}

const TEXT = { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store" };
