"use client";

import { useCallback, useEffect, useRef } from "react";
import "leaflet/dist/leaflet.css";
import type { RoutePoint } from "@/lib/types";
import { useClientPref } from "@/lib/clientPref";
import { getTileSpec, mapStylePref, type MapStyleId } from "@/lib/mapStyles";

// Leaflet touches `window` at import time, so it's loaded dynamically inside
// the effect (never during SSR). Markers use circleMarker so there are no
// bundler-broken default icon assets to ship. The basemap follows the user's
// saved style (lib/mapStyles) and swaps live when the style or theme changes.
export function RouteMap({
  route,
  color,
  height = 440,
}: {
  route: RoutePoint[];
  color: string;
  height?: number;
}) {
  const elRef = useRef<HTMLDivElement>(null);
  const mapRef = useRef<import("leaflet").Map | null>(null);
  const tileRef = useRef<import("leaflet").TileLayer | null>(null);
  const lRef = useRef<typeof import("leaflet") | null>(null);
  const styleRef = useRef<MapStyleId>("auto");
  // Changes from the settings page (same-tab event) and other tabs (storage).
  const styleId = useClientPref(mapStylePref);

  // (Re)point the active tile layer at the resolved style. Reads from refs so
  // it's safe to call from the MutationObserver's stale closure — which is also
  // why it has no dependencies and stays referentially stable.
  const applyTiles = useCallback(() => {
    const L = lRef.current;
    const map = mapRef.current;
    if (!L || !map) return;
    const isDark = document.documentElement.getAttribute("data-theme") !== "light";
    const spec = getTileSpec(styleRef.current, isDark);
    if (tileRef.current) map.removeLayer(tileRef.current);
    tileRef.current = L.tileLayer(spec.url, {
      subdomains: spec.subdomains ?? "abc",
      attribution: spec.attribution,
      maxZoom: spec.maxZoom,
      maxNativeZoom: spec.maxNativeZoom,
      // The page's Referrer-Policy is same-origin; tile servers (OpenStreetMap's
      // usage policy among them) expect a Referer, so the tiles send the
      // origin alone — what browsers sent by default before — and no path.
      referrerPolicy: "strict-origin-when-cross-origin",
    }).addTo(map);
    tileRef.current.bringToBack();
  }, []);

  // Build the map once per route.
  useEffect(() => {
    if (!elRef.current || route.length < 2) return;
    let cancelled = false;
    let themeObserver: MutationObserver | null = null;

    (async () => {
      const L = await import("leaflet");
      if (cancelled || !elRef.current) return;
      lRef.current = L;

      const latlngs: [number, number][] = route.map((p) => [p.lat, p.lon]);
      const map = L.map(elRef.current, {
        zoomControl: true,
        attributionControl: true,
        scrollWheelZoom: false, // don't hijack page scroll; click to zoom
      });
      mapRef.current = map;

      applyTiles();

      // Casing under the line for contrast over busy map tiles.
      L.polyline(latlngs, { color: "#000", weight: 7, opacity: 0.25, lineJoin: "round" }).addTo(map);
      const line = L.polyline(latlngs, { color, weight: 4, opacity: 0.95, lineJoin: "round" }).addTo(map);

      const dot = (fill: string) =>
        ({ radius: 7, color: "#fff", weight: 2.5, fillColor: fill, fillOpacity: 1 }) as const;
      L.circleMarker(latlngs[0], dot("#30d158")).bindTooltip("Start").addTo(map);
      L.circleMarker(latlngs[latlngs.length - 1], dot("#ff453a")).bindTooltip("Finish").addTo(map);

      map.fitBounds(line.getBounds(), { padding: [28, 28] });

      // Re-tile on theme change so the "auto" style keeps matching.
      themeObserver = new MutationObserver(() => applyTiles());
      themeObserver.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });
    })();

    return () => {
      cancelled = true;
      themeObserver?.disconnect();
      mapRef.current?.remove();
      mapRef.current = null;
      tileRef.current = null;
    };
  }, [route, color, applyTiles]);

  // Swap tiles when the chosen style changes.
  useEffect(() => {
    styleRef.current = styleId;
    applyTiles();
  }, [styleId, applyTiles]);

  return (
    <div
      ref={elRef}
      role="region"
      aria-label="Workout route map"
      style={{ height, width: "100%", borderRadius: 14, overflow: "hidden", border: "1px solid var(--border)", zIndex: 0 }}
    />
  );
}
