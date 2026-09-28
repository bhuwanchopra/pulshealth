import { formatSleepPeriodLabel, sleepScoreClassification, type SleepDay, type SleepScore } from "@/lib/sleep";

type ScoredNight = { night: SleepDay; score: SleepScore };

function scoreColor(score: number): string {
  if (score >= 96) return "var(--success, var(--accent))";
  if (score >= 81) return "var(--accent)";
  if (score >= 61) return "var(--fg-soft)";
  if (score >= 41) return "var(--muted)";
  return "var(--faint)";
}

export function SleepScoreHistoryChart({ scores }: { scores: ScoredNight[] }) {
  const points = [...scores].sort((a, b) => a.night.date.localeCompare(b.night.date));
  if (!points.length) return null;

  const width = 1000;
  const height = 280;
  const left = 42;
  const right = 16;
  const top = 18;
  const bottom = 42;
  const plotWidth = width - left - right;
  const plotHeight = height - top - bottom;
  const x = (index: number) => left + (points.length === 1 ? plotWidth / 2 : (index / (points.length - 1)) * plotWidth);
  const y = (score: number) => top + ((100 - Math.max(0, Math.min(100, score))) / 100) * plotHeight;
  const polyline = points.map((point, index) => `${x(index)},${y(point.score.score)}`).join(" ");
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
        <svg
          viewBox={`0 0 ${width} ${height}`}
          role="img"
          aria-label="Sleep Score history"
          style={{ display: "block", width: "100%", height: "auto", minHeight: 180 }}
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
              <text x={left - 8} y={y(score) + 4} textAnchor="end" fill="var(--faint)" fontSize="11">
                {score}
              </text>
            </g>
          ))}

          <polyline
            points={polyline}
            fill="none"
            stroke="var(--accent)"
            strokeWidth="3"
            strokeLinejoin="round"
            strokeLinecap="round"
          />

          {points.map((point, index) => (
            <circle
              key={point.night.date}
              cx={x(index)}
              cy={y(point.score.score)}
              r={points.length > 180 ? 2 : 3.5}
              fill={scoreColor(point.score.score)}
              stroke="var(--bg)"
              strokeWidth="1.5"
            >
              <title>
                {`${formatSleepPeriodLabel(point.night.date, "1 day")} · ${point.score.score}/100 · ${sleepScoreClassification(point.score.score)} · Duration ${Math.round(point.score.durationPoints)}/50 · Consistency ${Math.round(point.score.consistencyPoints)}/30 · Interruptions ${Math.round(point.score.interruptionPoints)}/20`}
              </title>
            </circle>
          ))}

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

      <div style={{ display: "flex", flexWrap: "wrap", gap: "8px 16px", marginTop: 4, color: "var(--faint)", fontSize: 11 }}>
        <span>0–40 Very Low</span>
        <span>41–60 Low</span>
        <span>61–80 OK</span>
        <span>81–95 High</span>
        <span>96–100 Very High</span>
      </div>
    </section>
  );
}
