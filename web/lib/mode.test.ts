import { describe, expect, it } from "vitest";

import { isTrue, trustProxyHeaders, viewerMode } from "./mode";

describe("viewerMode", () => {
  it("is accounts when WEB_ACCOUNTS is on, whatever else is set", () => {
    expect(viewerMode({ WEB_ACCOUNTS: "true" })).toBe("accounts");
    expect(viewerMode({ WEB_ACCOUNTS: "1", WEB_AUTH_PASSWORD: "x" })).toBe("accounts");
  });

  it("falls back to basic with a password, open without", () => {
    expect(viewerMode({ WEB_ACCOUNTS: "false", WEB_AUTH_PASSWORD: "pw" })).toBe("basic");
    expect(viewerMode({ WEB_ACCOUNTS: "" })).toBe("open");
    expect(viewerMode({})).toBe("open");
  });

  it("reads flags the way the Go services do", () => {
    for (const on of ["true", "TRUE", "1", "yes", "on", " true "]) expect(isTrue(on), on).toBe(true);
    for (const off of [undefined, "", "false", "0", "no", "off", "truthy"]) expect(isTrue(off), String(off)).toBe(false);
    expect(trustProxyHeaders({ TRUST_PROXY_HEADERS: "true" })).toBe(true);
    expect(trustProxyHeaders({})).toBe(false);
  });
});
