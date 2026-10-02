import { describe, expect, it } from "vitest";

import { allowedOrigins, clientIp, clientIpHeader, isSameOriginRequest, isSecureRequest, isUnsafeMethod, publicOrigin } from "./request";

const h = (init: Record<string, string>) => new Headers(init);
const u = (s: string) => new URL(s);

describe("clientIp", () => {
  it("ignores every forwarding header unless proxy headers are trusted", () => {
    const headers = h({ "x-forwarded-for": "198.51.100.7", "cf-connecting-ip": "203.0.113.1" });
    expect(clientIp(headers, false)).toBe("direct");
    expect(clientIp(headers, true, "x-forwarded-for")).toBe("198.51.100.7");
    expect(clientIp(headers, true, "cf-connecting-ip")).toBe("203.0.113.1");
    expect(clientIp(h({ "x-forwarded-for": "198.51.100.7, 10.0.0.2" }), true, "x-forwarded-for")).toBe("198.51.100.7");
    expect(clientIp(h({}), true, "x-forwarded-for")).toBe("unknown");
  });

  it("reads WEB_CLIENT_IP_HEADER, defaulting to X-Forwarded-For", () => {
    expect(clientIpHeader({})).toBe("x-forwarded-for");
    expect(clientIpHeader({ WEB_CLIENT_IP_HEADER: "CF-Connecting-IP" })).toBe("cf-connecting-ip");
    expect(clientIpHeader({ WEB_CLIENT_IP_HEADER: "x-evil" })).toBe("x-forwarded-for");
  });
});

describe("isSecureRequest", () => {
  it("believes X-Forwarded-Proto only when trusted", () => {
    const url = u("http://viewer.example/login");
    const fwd = h({ "x-forwarded-proto": "https" });
    expect(isSecureRequest(url, fwd, false, false)).toBe(false);
    expect(isSecureRequest(url, fwd, true, false)).toBe(true);
    expect(isSecureRequest(url, h({ "x-forwarded-proto": "http" }), true, false)).toBe(false);
    expect(isSecureRequest(u("https://viewer.example/"), h({}), false, false)).toBe(true);
  });

  it("counts http://localhost in development only", () => {
    expect(isSecureRequest(u("http://localhost:3000/"), h({}), false, true)).toBe(true);
    expect(isSecureRequest(u("http://localhost:3000/"), h({}), false, false)).toBe(false);
    expect(isSecureRequest(u("http://192.168.1.5:3001/"), h({}), false, true)).toBe(false);
  });
});

describe("isSameOriginRequest", () => {
  const url = u("http://web:3000/api/auth/login");
  const behindProxy = (extra: Record<string, string>) =>
    h({ host: "viewer.example", "x-forwarded-proto": "https", ...extra });

  it("lets safe methods through without looking", () => {
    expect(isUnsafeMethod("GET")).toBe(false);
    expect(isSameOriginRequest("GET", url, h({ origin: "https://evil.example" }), true, false, undefined)).toBe(true);
  });

  it("requires a POST to name this origin", () => {
    expect(isSameOriginRequest("POST", url, behindProxy({ origin: "https://viewer.example" }), true, false, undefined)).toBe(true);
    expect(isSameOriginRequest("POST", url, behindProxy({ origin: "https://evil.example" }), true, false, undefined)).toBe(false);
    expect(isSameOriginRequest("POST", url, behindProxy({}), true, false, undefined)).toBe(false);
    expect(isSameOriginRequest("POST", url, behindProxy({ origin: "null" }), true, false, undefined)).toBe(false);
    // A look-alike host with the right scheme is still another origin.
    expect(isSameOriginRequest("POST", url, behindProxy({ origin: "https://viewer.example.evil.example" }), true, false, undefined)).toBe(false);
  });

  it("behind a trusted TLS proxy, refuses a plain-http Origin for the same host", () => {
    expect(isSameOriginRequest("POST", url, behindProxy({ origin: "http://viewer.example" }), true, false, undefined)).toBe(false);
  });

  it("accepts the dev server's own http://localhost origin", () => {
    const dev = u("http://localhost:3005/api/auth/login");
    const headers = h({ host: "localhost:3005", origin: "http://localhost:3005" });
    expect(isSameOriginRequest("POST", dev, headers, false, true, undefined)).toBe(true);
  });

  it("refuses anything Sec-Fetch-Site calls cross-site", () => {
    const headers = behindProxy({ origin: "https://viewer.example", "sec-fetch-site": "cross-site" });
    expect(isSameOriginRequest("POST", url, headers, true, false, undefined)).toBe(false);
    const same = behindProxy({ origin: "https://viewer.example", "sec-fetch-site": "same-origin" });
    expect(isSameOriginRequest("POST", url, same, true, false, undefined)).toBe(true);
  });

  it("uses X-Forwarded-Host only when trusted, and WEB_PUBLIC_URL always", () => {
    const rewritten = h({ host: "web:3000", "x-forwarded-host": "viewer.example", "x-forwarded-proto": "https", origin: "https://viewer.example" });
    expect(isSameOriginRequest("POST", url, rewritten, true, false, undefined)).toBe(true);
    expect(isSameOriginRequest("POST", url, rewritten, false, false, undefined)).toBe(false);
    expect(isSameOriginRequest("POST", url, rewritten, false, false, "https://viewer.example/")).toBe(true);
    expect(allowedOrigins(url, rewritten, false, false, "not a url").has("not a url")).toBe(false);
  });
});

describe("publicOrigin", () => {
  const url = u("http://web:3000/workouts");
  it("prefers WEB_PUBLIC_URL, then trusted forwarding headers, then the URL", () => {
    const fwd = h({ host: "viewer.example", "x-forwarded-proto": "https" });
    expect(publicOrigin(url, fwd, true, "https://app.example/x")).toBe("https://app.example");
    expect(publicOrigin(url, fwd, true, undefined)).toBe("https://viewer.example");
    expect(publicOrigin(url, fwd, false, undefined)).toBe("http://web:3000");
    expect(publicOrigin(url, h({ host: "viewer.example", "x-forwarded-proto": "javascript" }), true, undefined)).toBe("http://web:3000");
  });
});
