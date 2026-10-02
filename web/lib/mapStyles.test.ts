import { afterEach, describe, expect, it, vi } from "vitest";
import { DEFAULT_MAP_STYLE, MAP_STYLES, getTileSpec, readMapStyle } from "./mapStyles";

describe("map styles", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  // CARTO's basemaps have drawn "API KEY REQUIRED" over every keyless tile
  // since September 2026; the viewer has no key to send, nor anywhere to keep one.
  it("draws every style from keyless tiles, none of them CARTO's", () => {
    for (const style of MAP_STYLES) {
      for (const isDark of [true, false]) {
        const { url } = style.spec ?? getTileSpec(style.id, isDark);
        expect(url).not.toMatch(/cartocdn\.com/);
        expect(url).not.toMatch(/api_?key|access_token|[?&]key=/i);
      }
    }
  });

  it("resolves auto against the theme", () => {
    expect(getTileSpec("auto", true).url).toContain("World_Dark_Gray_Base");
    expect(getTileSpec("auto", false).url).toContain("World_Light_Gray_Base");
  });

  // Past level 16 the Canvas services serve a "Map data not yet available" tile.
  it("scales Canvas tiles up past level 16 rather than fetching deeper ones", () => {
    for (const isDark of [true, false]) {
      const spec = getTileSpec("auto", isDark);
      expect(spec.maxNativeZoom).toBe(16);
      expect(spec.maxZoom).toBeGreaterThan(16);
    }
  });

  it("reads a retired style back as the default", () => {
    vi.stubGlobal("window", {});
    vi.stubGlobal("localStorage", { getItem: () => "voyager" });
    expect(readMapStyle()).toBe(DEFAULT_MAP_STYLE);
  });
});
