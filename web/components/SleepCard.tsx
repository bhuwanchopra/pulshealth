import Link from "next/link";
import { calculateSleepScore, sleepScoreClassification, type SleepDay } from "@/lib/sleep";

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
  recentNights = [],
}: {
  sleep: SleepDay | null;
  compact?: boolean;
  recentNights?: SleepDay[];
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
  const score = recentNights.length > 0 ? calculateSleepScore(sleep, recentNights) : null;
  const rows = STAGES.map((stage) => ({
    ...stage,
    minutes: sleep[stage.key],
  }));

  return (
    <Link href="/sleep" className="card" style={{ padding: compact ? 16 : 20, display: "block" }}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", gap: 16 }}>
        <div>
          <div className="eyebrow" style={{ color: "var(--muted)" }}>Sleep</div>
          <div className="metric-num" style={{ fontSize: compact ? 28 : 34, fontWeight: 600, marginTop: 5 }}>
            {hoursAndMinutes(asleep)}
          </div>
        </div>
        {score && (
          <div style={{ textAlign: "right", flex: "none" }}>
            <div className="eyebrow" style={{ color: "var(--muted)" }}>Sleep score</div>
            <div className="metric-num" style={{ fontSize: compact ? 28 : 34, fontWeight: 650, lineHeight: 1, marginTop: 6 }}>
              {score.score}
              <span style={{ fontSize: 12, color: "var(--muted)", fontWeight: 400 }}> / 100</span>
            </div>
            <div style={{ color: "var(--faint)", fontSize: 11.5, marginTop: 5 }}>
              {sleepScoreClassification(score.score)}
            </div>
          </div>
        )}
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

      {!compact && score && (
        <div style={{ display: "grid", gridTemplateColumns: "repeat(3, minmax(0, 1fr))", gap: 8, marginTop: 16 }}>
          {[
            ["Duration", score.durationPoints, 50],
            ["Consistency", score.consistencyPoints, 30],
            ["Interruptions", score.interruptionPoints, 20],
          ].map(([label, value, max]) => (
            <div key={String(label)} style={{ padding: "9px 10px", borderRadius: 10, background: "var(--bg-soft)", border: "1px solid var(--border)" }}>
              <div style={{ color: "var(--faint)", fontSize: 10.5 }}>{label}</div>
              <div className="mono" style={{ fontSize: 13, marginTop: 3 }}>{Math.round(Number(value))}<span style={{ color: "var(--faint)" }}>/{max}</span></div>
            </div>
          ))}
        </div>
      )}

      {!compact && score && (
        <div style={{ fontSize: 10.5, color: "var(--faint)", marginTop: 10 }}>
          Derived from duration, bedtime consistency, and awake interruptions. Not Apple’s proprietary score.
        </div>
      )}

      {!compact && sleep.unspecifiedMinutes > 0 && (
        <div style={{ fontSize: 11.5, color: "var(--faint)", marginTop: 12 }}>
          {hoursAndMinutes(sleep.unspecifiedMinutes)} unspecified asleep
        </div>
      )}
    </Link>
  );
}
