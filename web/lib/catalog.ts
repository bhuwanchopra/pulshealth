// The web catalog: the published type vocabulary merged with a web-only overlay.
//
// The core — identifiers, kinds, canonical units, groups, display names — is
// `./catalog.generated.ts`, rendered by `npm run gen:catalog` from
// `docs/protocol/catalog.json`, which the PulsHealthSync package tests render
// from the Swift `HealthTypeCatalog` (the source of truth, because HealthKit's
// constraints live there). Nothing in this file restates a type, so the viewer
// cannot drift from the app; `npm run check:catalog` fails in CI when the
// generated file is stale. Add web-only presentation here (a name override, a
// web-only flag); add types in the Swift catalog and regenerate.

import {
  CATALOG_GROUPS,
  GENERATED_CATALOG,
  type AggregateFunction,
  type AggregationStyle,
  type Group,
  type Kind,
} from "./catalog.generated";

export type { AggregateFunction, AggregationStyle, Group, Kind };

export interface HealthType {
  /** HealthKit identifier, e.g. "HKQuantityTypeIdentifierStepCount" — primary key, matches sample_types.identifier in Postgres */
  identifier: string;
  /** Human-friendly display name, e.g. "Heart Rate" (the app's, unless overridden below) */
  name: string;
  /** Canonical unit string, e.g. "count/min", or null for category/workout/series kinds */
  unit: string | null;
  kind: Kind;
  group: Group;
  /** estimatedSamplesPerDay density hint */
  perDay: number;
  /** HealthKit aggregation style for quantity types; null for every other kind */
  aggregationStyle: AggregationStyle | null;
  /** Aggregate functions HealthKit accepts for this type (empty for non-quantity kinds) */
  allowedAggregateFunctions: readonly AggregateFunction[];
  /** First iOS release the app exports this type on, e.g. "18.0" */
  minimumIOS: string;
}

/**
 * Web-only overrides by identifier. A `name` here replaces the app's display
 * name in the viewer; everything else always comes from the generated core.
 */
const OVERLAY: Partial<Record<string, { name?: string }>> = {
  HKCategoryTypeIdentifierSleepAnalysis: { name: "Sleep Duration" },
};

/** Every type the app can sync, sorted by identifier (the vocabulary's order). */
export const CATALOG: HealthType[] = GENERATED_CATALOG.map((t) => ({
  identifier: t.identifier,
  name: OVERLAY[t.identifier]?.name ?? t.displayName,
  unit: t.unit,
  kind: t.kind,
  group: t.group,
  perDay: t.estimatedSamplesPerDay,
  aggregationStyle: t.aggregationStyle,
  allowedAggregateFunctions: t.allowedAggregateFunctions,
  minimumIOS: t.minimumIOS,
}));

/** Groups in the app's display order. */
export const GROUPS: Group[] = CATALOG_GROUPS.map((g) => g.key);

export const GROUP_LABELS: Record<Group, string> = Object.fromEntries(
  CATALOG_GROUPS.map((g) => [g.key, g.label]),
) as Record<Group, string>;

const BY_ID = new Map(CATALOG.map((t) => [t.identifier, t]));

// Quantity, category, and workout records have complete viewer routes. The
// remaining series-like tables are synced, but do not yet have honest detail
// views, so keep them out of navigation until those views exist.
export const BROWSABLE_CATALOG = CATALOG.filter((t) =>
  t.kind === "quantity" || t.kind === "category" || t.kind === "workout",
);

export function typeByIdentifier(id: string): HealthType | undefined {
  return BY_ID.get(id);
}
export function typesInGroup(g: Group): HealthType[] {
  return BROWSABLE_CATALOG.filter((t) => t.group === g);
}
export function typeHref(type: HealthType): string | null {
  if (type.kind === "workout") return "/workouts";
  if (type.kind === "quantity" || type.kind === "category") {
    return `/type/${encodeURIComponent(type.identifier)}`;
  }
  return null;
}
