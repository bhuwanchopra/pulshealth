import { describe, expect, it } from "vitest";

import { classifyPath, decideAccounts, unauthenticatedAnswer } from "./policy";

describe("classifyPath", () => {
  it("sorts every route class", () => {
    expect(classifyPath("/api/healthz")).toBe("health");
    expect(classifyPath("/_next/static/chunks/app.js")).toBe("asset");
    expect(classifyPath("/icon.svg")).toBe("asset");
    expect(classifyPath("/login")).toBe("public");
    expect(classifyPath("/invite/abc")).toBe("public");
    expect(classifyPath("/api/auth/login")).toBe("public");
    expect(classifyPath("/api/auth/invite")).toBe("public");
    expect(classifyPath("/api/auth/logout")).toBe("public");
    for (const path of [
      "/",
      "/workouts",
      "/type/HKQuantityTypeIdentifierStepCount",
      "/account",
      "/settings",
      "/api/user",
      "/api/auth/password",
      "/api/auth/sessions",
      "/login/extra",
      "/invite/abc/def",
      "/invite/",
      "/_next/image",
      "/__nextjs_original-stack-frame",
      "/api/healthz/x",
    ]) {
      expect(classifyPath(path), path).toBe("protected");
    }
    expect(classifyPath("/__nextjs_original-stack-frame", true)).toBe("asset");
  });
});

describe("decideAccounts", () => {
  const facts = (pathname: string, over: Partial<{ secure: boolean; sameOrigin: boolean }> = {}) => ({
    pathname,
    secure: true,
    sameOrigin: true,
    development: false,
    ...over,
  });

  it("answers the health check and assets whatever the transport", () => {
    expect(decideAccounts(facts("/api/healthz", { secure: false, sameOrigin: false }))).toBe("pass");
    expect(decideAccounts(facts("/_next/static/x.js", { secure: false }))).toBe("pass");
  });

  it("refuses plain HTTP everywhere else, the sign-in page included", () => {
    expect(decideAccounts(facts("/login", { secure: false }))).toBe("insecure");
    expect(decideAccounts(facts("/", { secure: false }))).toBe("insecure");
  });

  it("refuses cross-origin writes before anything else", () => {
    expect(decideAccounts(facts("/api/auth/login", { sameOrigin: false }))).toBe("cross-origin");
    expect(decideAccounts(facts("/api/auth/logout", { sameOrigin: false }))).toBe("cross-origin");
  });

  it("serves public routes and asks for a session everywhere else", () => {
    expect(decideAccounts(facts("/login"))).toBe("pass");
    expect(decideAccounts(facts("/invite/tok"))).toBe("pass");
    expect(decideAccounts(facts("/"))).toBe("session");
    expect(decideAccounts(facts("/api/auth/password"))).toBe("session");
  });

  it("redirects page loads to sign in and answers the rest 401", () => {
    expect(unauthenticatedAnswer("GET", "/workouts")).toBe("redirect");
    expect(unauthenticatedAnswer("HEAD", "/")).toBe("redirect");
    expect(unauthenticatedAnswer("POST", "/account")).toBe("unauthorized");
    expect(unauthenticatedAnswer("GET", "/api/user")).toBe("unauthorized");
  });
});
