import type { SleepDay } from "@/lib/sleep";

const STAGES = [
  { key: "coreMinutes", label: "Core", color: "rgb(96 165 250)" },
  { key: "deepMinutes", label: "Deep", color: "rgb(99 102 241)" },
  { key: "remMinutes", label: "REM", color: "rgb(192 132 252)" },
  { key: "unspecifiedMinutes", label: "Unspecified", color: "rgb(148 163 184)" },
  { key: "awakeMinutes", label: "Awake", color: "rgb(251 191 36)" },
] as const;

function hoursAndMinutes(minutes: number): string {
  const total = Math.max(0, Math.round(minutes));
  const hours = Math.floor(total / 60);
  const mins = total % 60;
  return hours ? `${hours}h ${mins}m` : `${mins}m`;
}

function formatDate(date: string): string {
  const parsed = new Date(`${date}T12:00:00`);
  if (Number.isNaN(parsed.getTime())) return date;
  return new Intl.DateTimeFormat("en-US", {
    month: "short",
    day: "numeric",
  }).format(parsed);
}

export function SleepHistoryChart({ nights }: { nights: SleepDay[] }) {
  const maxMinutes = Math.max(
    1,
    ...nights.map((night) =>
      Math.max(
        night.inBedMinutes,
        night.asleepMinutes + night.awakeMinutes,
        night.coreMinutes +
          night.deepMinutes +
          night.remMinutes +
          night.unspecifiedMinutes +
          night.awakeMinutes,
      ),
    ),
  );
  const axisMax = Math.max(8 * 60, Math.ceil(maxMinutes / 60) * 60);
  const axisStep = axisMax >= 12 * 60 ? 3 * 60 : 2 * 60;
  const ticks = Array.from(
    { length: Math.floor(axisMax / axisStep) + 1 },
    (_, index) => index * axisStep,
  ).filter((minutes) => minutes <= axisMax);
  const chartHeight = 260;
  const barWidth = nights.length > 90 ? 12 : 22;
  const gap = nights.length > 90 ? 3 : 7;
  const labelCount = Math.min(6, nights.length);
  const labelStep = Math.max(1, Math.ceil(Math.max(0, nights.length - 1) / Math.max(1, labelCount - 1)));
  const labelIndexes = new Set<number>();
  for (let i = 0; i < nights.length; i += labelStep) labelIndexes.add(i);
  if (nights.length) labelIndexes.add(nights.length - 1);

  return (
    <section className="panel" style={{ padding: 20 }}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline", gap: 16 }}>
        <div>
          <div className="eyebrow" style={{ color: "var(--muted)" }}>History</div>
          <h2 style={{ margin: "5px 0 0", fontSize: 20 }}>Sleep stages</h2>
          <div style={{ color: "var(--muted)", fontSize: 13, marginTop: 5 }}>
            {nights.some((night) => (night.nights ?? 1) > 1)
              ? "Each bar is the average night for its time bucket, stacked by stage duration."
              : "Each bar is one night, stacked by stage duration."}
          </div>
        </div>
        <div style={{ color: "var(--faint)", fontSize: 12 }}>{nights.reduce((sum, night) => sum + (night.nights ?? 1), 0)} nights</div>
      </div>

      <div style={{ display: "flex", flexWrap: "wrap", gap: "8px 16px", marginTop: 18, color: "var(--muted)", fontSize: 12 }}>
        {STAGES.map((stage) => (
          <div key={stage.key} style={{ display: "flex", alignItems: "center", gap: 6 }}>
            <span aria-hidden="true" style={{ width: 9, height: 9, borderRadius: 3, background: stage.color }} />
            {stage.label}
          </div>
        ))}
      </div>

      <div style={{ display: "grid", gridTemplateColumns: "34px minmax(0, 1fr)", gap: 10, marginTop: 18 }}>
        <div style={{ position: "relative", height: chartHeight, color: "var(--faint)", fontSize: 10 }}>
          {ticks.map((minutes) => (
            <span
              key={minutes}
              style={{
                position: "absolute",
                right: 0,
                bottom: `${(minutes / axisMax) * 100}%`,
                transform: "translateY(50%)",
              }}
            >
              {minutes / 60}h
            </span>
          ))}
        </div>

        <div style={{ minWidth: 0, overflowX: nights.length > 30 ? "auto" : "visible" }}>
          <div style={{ minWidth: Math.max(0, nights.length * (barWidth + gap)), paddingBottom: 2 }}>
            <div
              style={{
                position: "relative",
                height: chartHeight,
                display: "flex",
                alignItems: "flex-end",
                gap,
                padding: "0 2px",
                backgroundImage: `linear-gradient(to top, transparent calc(100% - 1px), var(--border) calc(100% - 1px))`,
                backgroundSize: `100% ${(axisStep / axisMax) * 100}%`,
              }}
            >
              {nights.map((night) => {
                const inBed = Math.max(0, night.inBedMinutes);
                const stageTotal =
                  night.coreMinutes +
                  night.deepMinutes +
                  night.remMinutes +
                  night.unspecifiedMinutes +
                  night.awakeMinutes;
                const total = Math.max(inBed, stageTotal);
                const barHeight = (Math.min(axisMax, total) / axisMax) * chartHeight;

                return (
                  <div
                    key={night.date}
                    style={{
                      width: barWidth,
                      height: Math.max(2, barHeight),
                      flex: `0 0 ${barWidth}px`,
                      display: "flex",
                      flexDirection: "column",
                      justifyContent: "flex-end",
                      overflow: "hidden",
                      borderRadius: "5px 5px 2px 2px",
                      background: "var(--border)",
                    }}
                    title={`${formatDate(night.date)} · ${hoursAndMinutes(night.asleepMinutes)} asleep · ${hoursAndMinutes(night.inBedMinutes)} in bed`}
                  >
                    {STAGES.map((stage) => {
                      const minutes = Math.max(0, night[stage.key]);
                      if (!minutes) return null;
                      return (
                        <div
                          key={stage.key}
                          style={{
                            height: `${Math.min(minutes, axisMax) / axisMax * chartHeight}px`,
                            minHeight: 1,
                            background: stage.color,
                            flex: "0 0 auto",
                          }}
                          title={`${formatDate(night.date)} — ${stage.label}: ${hoursAndMinutes(minutes)}`}
                        />
                      );
                    })}
                  </div>
                );
              })}
            </div>

            <div
              style={{
                display: "flex",
                gap,
                padding: "8px 2px 0",
                borderTop: "1px solid var(--border)",
              }}
            >
              {nights.map((night, index) => (
                <div
                  key={night.date}
                  style={{
                    width: barWidth,
                    flex: `0 0 ${barWidth}px`,
                    textAlign: "center",
                    color: "var(--muted)",
                    fontSize: 10,
                    whiteSpace: "nowrap",
                  }}
                >
                  {labelIndexes.has(index) ? formatDate(night.date) : ""}
                </div>
              ))}
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}
