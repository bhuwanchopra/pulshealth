import Link from "next/link";
import { type SleepDay } from "@/lib/sleep";

const STAGES = [
  { key: "coreMinutes", label: "Core" },
  { key: "deepMinutes", label: "Deep" },
  { key: "remMinutes", label: "REM" },
] as const;

function hoursAndMinutes(minutes: number): string {
  const total = Math.max(0, Math.round(minutes));
  const hours = Math.floor(total / 60);
  const mins = total % 60;
  return hours ? `${hours}h ${mins}m` : `${mins}m`;
}

function pct(value: number, total: number): number {
  return total > 0 ? Math.max(0, Math.min(100, (value / total) * 100)) : 0;
}

export function SleepCard({
  sleep,
  compact = false,
}: {
  sleep: SleepDay | null;
  compact?: boolean;
}) {
  if (!sleep) {
    return (
      <div className="card" style={{ padding: 18 }}>
        <div style={{ fontSize: 13.5, color: "var(--fg-soft)" }}>Sleep</div>
        <div style={{ color: "var(--muted)", fontSize: 13, marginTop: 10 }}>
          No sleep-stage data recorded.
        </div>
      </div>
    );
  }

  const asleep = sleep.asleepMinutes;
  const rows = STAGES.map((stage) => ({
    ...stage,
    minutes: sleep[stage.key],
  }));

  return (
    <Link href="/sleep" className="card" style={{ padding: compact ? 16 : 20, display: "block" }}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", gap: 16 }}>
        <div>
          <div className="eyebrow" style={{ color: "var(--muted)" }}>Sleep Duration</div>
          <div className="metric-num" style={{ fontSize: compact ? 28 : 34, fontWeight: 600, marginTop: 5 }}>
            {hoursAndMinutes(asleep)}
          </div>
        </div>
        <div style={{ color: "var(--faint)", fontSize: 12, textAlign: "right" }}>
          {sleep.date}
          <br />
          {hoursAndMinutes(sleep.inBedMinutes)} in bed
        </div>
      </div>

      <div style={{ marginTop: 18, display: "grid", gap: 10 }}>
        {rows.map((row) => (
          <div key={row.key}>
            <div style={{ display: "flex", justifyContent: "space-between", fontSize: 12 }}>
              <span style={{ color: "var(--fg-soft)" }}>{row.label}</span>
              <span className="mono" style={{ color: "var(--muted)" }}>{hoursAndMinutes(row.minutes)}</span>
            </div>
            <div style={{ height: 7, marginTop: 5, borderRadius: 999, background: "var(--border)" }}>
              <div
                style={{
                  height: "100%",
                  width: `${pct(row.minutes, asleep)}%`,
                  borderRadius: 999,
                  background: "var(--accent)",
                  opacity: row.key === "deepMinutes" ? 0.95 : row.key === "remMinutes" ? 0.7 : 0.45,
                }}
              />
            </div>
          </div>
        ))}

        {sleep.awakeMinutes > 0 && (
          <div style={{ display: "flex", justifyContent: "space-between", fontSize: 12, color: "var(--muted)" }}>
            <span>Awake</span>
            <span className="mono">{hoursAndMinutes(sleep.awakeMinutes)}</span>
          </div>
        )}
      </div>

      {!compact && sleep.unspecifiedMinutes > 0 && (
        <div style={{ fontSize: 11.5, color: "var(--faint)", marginTop: 12 }}>
          {hoursAndMinutes(sleep.unspecifiedMinutes)} unspecified asleep
        </div>
      )}
    </Link>
  );
}
