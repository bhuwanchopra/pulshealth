"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { GROUPS, GROUP_LABELS } from "@/lib/catalog";
import { GROUP_COLOR } from "@/lib/colors";
import type { DataSourceInfo, User } from "@/lib/types";
import { GridIcon, GroupIcon, HomeIcon, SettingsIcon, SignOutIcon, UserIcon, WorkoutIcon } from "./Icons";
import { BrandMark } from "./BrandMark";
import { ThemeToggle } from "./ThemeToggle";
import { UserSwitcher } from "./UserSwitcher";

export function Sidebar({
  source,
  users,
  currentUserId,
  account = null,
}: {
  source: DataSourceInfo;
  users: User[];
  currentUserId: string;
  /** The signed-in account, in accounts mode; null otherwise. */
  account?: { email: string } | null;
}) {
  const path = usePathname();
  // A choice is only worth offering when there is one — or when the current
  // user (from a stale cookie or a bad ?user= link) is not in the list at
  // all, so the way back to a real user is one click away.
  const showSwitcher = users.length >= 2 || (users.length >= 1 && !users.some((u) => u.id === currentUserId));

  const primary = [
    { href: "/", label: "Today", icon: <HomeIcon className="nav-icon" /> },
    { href: "/workouts", label: "Workouts", icon: <WorkoutIcon className="nav-icon" /> },
    { href: "/data", label: "All Data", icon: <GridIcon className="nav-icon" /> },
  ];

  return (
    <aside className="sidebar">
      <Link href="/" className="brand">
        <span className="brand-mark">
          <BrandMark />
        </span>
        <span className="brand-name">PulsHealth</span>
      </Link>

      <nav>
        {primary.map((item) => {
          const active = item.href === "/" ? path === "/" : path.startsWith(item.href);
          return (
            <Link key={item.href} href={item.href} aria-current={active ? "page" : undefined} className={`nav-link${active ? " active" : ""}`}>
              {item.icon}
              <span>{item.label}</span>
            </Link>
          );
        })}
      </nav>

      <div className="nav-section">
        <div className="eyebrow" style={{ padding: "0 2px 8px" }}>
          Categories
        </div>
        {GROUPS.map((g) => {
          const href = g === "workouts" ? "/workouts" : `/category/${g}`;
          const active = path === href;
          return (
            <Link key={g} href={href} aria-current={active ? "page" : undefined} className={`nav-link${active ? " active" : ""}`}>
              <GroupIcon group={g} className="nav-icon" size={17} style={{ color: GROUP_COLOR[g] } as React.CSSProperties} />
              <span>{GROUP_LABELS[g]}</span>
            </Link>
          );
        })}
      </div>

      <div style={{ flex: 1 }} />

      <div className="nav-section" style={{ marginTop: 0 }}>
        {showSwitcher && <UserSwitcher users={users} currentUserId={currentUserId} />}
        {account && (
          <Link
            href="/account"
            aria-current={path === "/account" ? "page" : undefined}
            className={`nav-link${path === "/account" ? " active" : ""}`}
            title={`Signed in as ${account.email}`}
          >
            <UserIcon className="nav-icon" />
            <span style={{ overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{account.email}</span>
          </Link>
        )}
        <Link href="/settings" className={`nav-link${path === "/settings" ? " active" : ""}`}>
          <SettingsIcon className="nav-icon" />
          <span>Settings</span>
        </Link>
        <ThemeToggle />
        {account && (
          // A form post, not a link: signing out changes state, and works without JavaScript.
          <form method="post" action="/api/auth/logout">
            <button type="submit" className="nav-link" style={{ width: "100%", cursor: "pointer", background: "transparent" }}>
              <SignOutIcon className="nav-icon" />
              <span>Sign out</span>
            </button>
          </form>
        )}
        <div className="chip" style={{ marginTop: 10, width: "100%", justifyContent: "flex-start" }} title={source.detail}>
          <span
            className="dot"
            style={{ background: source.source === "live" ? "#30d158" : source.source === "demo" ? "#ff9f0a" : "#ff453a" }}
          />
          <span style={{ fontSize: 12 }}>
            {source.source === "live" ? "Live data" : source.source === "demo" ? "Demo data" : "Database unavailable"}
          </span>
        </div>
      </div>
    </aside>
  );
}
