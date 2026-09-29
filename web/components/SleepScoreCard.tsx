import Link from "next/link";
import { sleepScoreClassification, type SleepScore } from "@/lib/sleep";
import { GROUP_COLOR } from "@/lib/colors";
import { Sparkline } from "./Sparkline";

export function SleepScoreCard({
  score,
  history,
}: {
  score: SleepScore | null;
  history: SleepScore[];
}) {
  const color = GROUP_COLOR.sleep;
  const spark = history
    .slice()
    .reverse()
    .map((entry) => entry.score);

  return (
    <Link href="/sleep" className="card" style={{ padding: 18 }}>
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between" }}>
        <div style={{ display: "flex", alignItems: "center", gap: 8, minWidth: 0 }}>
          <span className="dot" style={{ background: color }} />
          <span style={{ color: "var(--fg-soft)", fontSize: 13.5 }}>Sleep Score</span>
        </div>
        {score && (
          <span style={{ color: "var(--faint)", fontSize: 11.5 }}>
            {score.night.date}
          </span>
        )}
      </div>

      <div style={{ display: "flex", alignItems: "flex-end", justifyContent: "space-between", gap: 12, marginTop: 14 }}>
        <div>
          <div className="metric-num" style={{ fontSize: 30, fontWeight: 600 }}>
            {score?.score ?? "—"}
            {score && <span style={{ fontSize: 13, fontWeight: 400, color: "var(--muted)", marginLeft: 4 }}>/ 100</span>}
          </div>
          {score && (
            <div style={{ fontSize: 11, color: "var(--faint)", marginTop: 4 }}>
              {sleepScoreClassification(score.score)}
            </div>
          )}
        </div>
        <Sparkline values={spark} color={color} />
      </div>
    </Link>
  );
}
