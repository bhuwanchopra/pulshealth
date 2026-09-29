import { formatSleepPeriodLabel, sleepScoreClassification, type SleepDay, type SleepScore } from "@/lib/sleep";

type ScoredNight = { night: SleepDay; score: SleepScore };

export function SleepScoreHistoryChart({ scores }: { scores: ScoredNight[] }) {
  const points = [...scores].sort((a, b) => a.night.date.localeCompare(b.night.date));
  if (!points.length) return null;

  const width = Math.max(1000, points.length * 28);
  const height = 280;
  const left = 42;
  const right = 16;
  const top = 18;
  const bottom = 42;
  const plotWidth = width - left - right;
  const plotHeight = height - top - bottom;
  const x = (index: number) => left + (points.length === 1 ? plotWidth / 2 : (index / (points.length - 1)) * plotWidth);
  const y = (score: number) => top + ((100 - Math.max(0, Math.min(100, score))) / 100) * plotHeight;
  const labelIndexes = new Set<number>();
  const labelCount = Math.min(6, points.length);
  const step = Math.max(1, Math.ceil(Math.max(0, points.length - 1) / Math.max(1, labelCount - 1)));
  for (let i = 0; i < points.length; i += step) labelIndexes.add(i);
  labelIndexes.add(points.length - 1);

  return (
    <section className="panel" style={{ padding: 20 }}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline", gap: 16 }}>
        <div>
          <div className="eyebrow" style={{ color: "var(--muted)" }}>History</div>
          <h2 style={{ margin: "5px 0 0", fontSize: 20 }}>Sleep Score</h2>
          <div style={{ color: "var(--muted)", fontSize: 13, marginTop: 5 }}>
            Derived score for every available night using the preceding 13 nights for bedtime consistency.
          </div>
        </div>
        <div style={{ color: "var(--faint)", fontSize: 12 }}>{points.length} scored nights</div>
      </div>

      <div style={{ marginTop: 18, overflow: "hidden" }}>
        <div style={{ overflowX: "auto", paddingBottom: 4 }}>
          <svg
            viewBox={`0 0 ${width} ${height}`}
            role="img"
            aria-label="Sleep Score history bar chart"
            style={{ display: "block", width: "100%", minWidth: points.length > 35 ? Math.max(700, points.length * 28) : "100%", height: "auto", minHeight: 180 }}
          >
            {[40, 60, 80, 95, 100].map((score) => (
              <g key={score}>
                <line
                  x1={left}
                  x2={width - right}
                  y1={y(score)}
                  y2={y(score)}
                  stroke="var(--border)"
                  strokeWidth="1"
                  strokeDasharray={score === 100 ? undefined : "4 5"}
                />
                <text x={left - 8} y={y(score) + 4} textAnchor="end" fill="var(--faint)" fontSize="11">{score}</text>
              </g>
            ))}

            {points.map((point, index) => {
              const barWidth = Math.max(5, Math.min(18, (plotWidth / Math.max(points.length, 1)) * 0.7));
              const barX = x(index) - barWidth / 2;
              return (
                <g key={point.night.date}>
                  <rect
                    x={barX}
                    y={y(point.score.score)}
                    width={barWidth}
                    height={Math.max(0, y(0) - y(point.score.score))}
                    rx="2"
                    fill={point.score.score >= 81 ? "#166534" : point.score.score >= 61 ? "#22c55e" : point.score.score >= 41 ? "#eab308" : "#ef4444"}
                  >
                    <title>
                      {formatSleepPeriodLabel(point.night.date, "1 day")} · {point.score.score}/100 · {sleepScoreClassification(point.score.score)} · Duration {Math.round(point.score.durationPoints)}/50 · Consistency {Math.round(point.score.consistencyPoints)}/30 · Interruptions {Math.round(point.score.interruptionPoints)}/20
                    </title>
                  </rect>
                </g>
              );
            })}

            {points.map((point, index) =>
              labelIndexes.has(index) ? (
                <text
                  key={`label-${point.night.date}`}
                  x={x(index)}
                  y={height - 14}
                  textAnchor={index === 0 ? "start" : index === points.length - 1 ? "end" : "middle"}
                  fill="var(--muted)"
                  fontSize="11"
                >
                  {formatSleepPeriodLabel(point.night.date, "1 day")}
                </text>
              ) : null,
            )}
          </svg>
        </div>
      </div>

      <div style={{ display: "flex", flexWrap: "wrap", gap: "8px 16px", marginTop: 4, color: "var(--faint)", fontSize: 11 }}>
        <span style={{ color: "#ef4444" }}>0–40 Very Low</span>
        <span style={{ color: "#eab308" }}>41–60 Low</span>
        <span style={{ color: "#22c55e" }}>61–80 OK</span>
        <span style={{ color: "#166534" }}>81–95 High</span>
        <span style={{ color: "#166534" }}>96–100 Very High</span>
      </div>
    </section>
  );
}
