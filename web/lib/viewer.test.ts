import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const queryMock = vi.hoisted(() => vi.fn());
// scoped() runs the callback's statements through the same mock; its
// transaction and user setting are lib/db.ts's business, tested there.
vi.mock("./db", () => ({
  query: queryMock,
  scoped: (_userId: string, fn: (q: typeof queryMock) => Promise<unknown>) => fn(queryMock),
}));

const DEFAULT = "5ea4d000-0000-4000-8000-000000000001";
const OTHER = "22222222-2222-4222-8222-222222222222";

describe("parseViewerUser", () => {
  it("takes a UUID cookie, lower-cased", async () => {
    const { parseViewerUser } = await import("./viewer");
    expect(parseViewerUser(OTHER, DEFAULT)).toBe(OTHER);
    expect(parseViewerUser(OTHER.toUpperCase(), DEFAULT)).toBe(OTHER);
  });

  it("falls back when the cookie is missing or not a UUID", async () => {
    const { parseViewerUser } = await import("./viewer");
    expect(parseViewerUser(undefined, DEFAULT)).toBe(DEFAULT);
    expect(parseViewerUser("", DEFAULT)).toBe(DEFAULT);
    expect(parseViewerUser("not-a-uuid", DEFAULT)).toBe(DEFAULT);
    expect(parseViewerUser("22222222-2222-4222-8222-22222222222", DEFAULT)).toBe(DEFAULT);
    expect(parseViewerUser(`${OTHER}'; DROP TABLE users;--`, DEFAULT)).toBe(DEFAULT);
  });
});

describe("safeReturnPath", () => {
  it("keeps same-origin paths and refuses everything else", async () => {
    const { safeReturnPath } = await import("./viewer");
    expect(safeReturnPath("/workouts?range=W")).toBe("/workouts?range=W");
    expect(safeReturnPath("/")).toBe("/");
    expect(safeReturnPath(undefined)).toBe("/");
    expect(safeReturnPath("")).toBe("/");
    expect(safeReturnPath("workouts")).toBe("/");
    expect(safeReturnPath("https://example.com/")).toBe("/");
    expect(safeReturnPath("//example.com/")).toBe("/");
    // Browsers strip tabs and newlines from URLs before parsing them, so these
    // would arrive as //evil.example.
    expect(safeReturnPath("/\t/evil.example")).toBe("/");
    expect(safeReturnPath("/\n/evil.example")).toBe("/");
    expect(safeReturnPath("/\r\n/evil.example")).toBe("/");
    expect(safeReturnPath("/x\\y")).toBe("/");
    expect(safeReturnPath("/workouts/a?b=1#c")).toBe("/workouts/a?b=1#c");
    // Dot segments that parsing collapses into a scheme-relative URL.
    for (const sneaky of ["/.//evil.example", "/..//evil.example", "/%2e//evil.example", "/a/..//evil.example", "/././/evil.example/x"]) {
      expect(safeReturnPath(sneaky), sneaky).toBe("/");
    }
    expect(safeReturnPath("/a/../workouts")).toBe("/workouts");
    expect(safeReturnPath("/\\example.com")).toBe("/");
  });
});

describe("getUsers", () => {
  beforeEach(() => {
    vi.resetModules();
    queryMock.mockReset();
  });
  afterEach(() => {
    vi.unstubAllEnvs();
  });

  it("lists the one demo user outside production without a database", async () => {
    vi.stubEnv("NODE_ENV", "development");
    vi.stubEnv("DATABASE_URL", "");
    const { getUsers } = await import("./queries");
    expect(await getUsers()).toEqual([{ id: DEFAULT, name: "Demo", email: null }]);
    expect(queryMock).not.toHaveBeenCalled();
  });

  it("lists nobody in production when the database is unavailable", async () => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("DATABASE_URL", "");
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const { getUsers } = await import("./queries");
    expect(await getUsers()).toEqual([]);
    expect(queryMock).not.toHaveBeenCalled();
    errorSpy.mockRestore();
  });

  it("returns the users table oldest first when live", async () => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("DATABASE_URL", "postgres://test");
    queryMock.mockImplementation((text: string) => {
      if (text.includes("FROM users")) {
        return Promise.resolve([
          { id: DEFAULT, name: null, email: null },
          { id: OTHER, name: "Alex", email: "alex@example.com" },
        ]);
      }
      return Promise.resolve([]);
    });
    const { getUsers } = await import("./queries");
    expect(await getUsers()).toEqual([
      { id: DEFAULT, name: null, email: null },
      { id: OTHER, name: "Alex", email: "alex@example.com" },
    ]);
    const sql = queryMock.mock.calls.find(([text]) => text.includes("FROM users"))?.[0] as string;
    expect(sql).toContain("ORDER BY created_at");
  });

  it("returns nobody in production when the live query fails", async () => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("DATABASE_URL", "postgres://test");
    queryMock.mockImplementation((text: string) => {
      if (text.includes("FROM users")) return Promise.reject(new Error("permission denied"));
      return Promise.resolve([]);
    });
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const { getUsers } = await import("./queries");
    expect(await getUsers()).toEqual([]);
    errorSpy.mockRestore();
  });
});
