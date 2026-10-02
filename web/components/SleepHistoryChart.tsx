import { formatSleepPeriodLabel, type SleepDay } from "@/lib/sleep";

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

export function SleepHistoryChart({
  nights,
  interval,
}: {
  nights: SleepDay[];
  interval: string;
}) {
  // Keep the chart's time direction consistent with the other metric charts:
  // oldest on the left, latest on the right.
  const displayNights = [...nights].reverse();

  const maxMinutes = Math.max(
    1,
    ...displayNights.map((night) =>
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
  // Match the other metric charts: bars always fill the available plot width.
  // Do not introduce horizontal scrolling as the history range grows.
  const gap = displayNights.length > 90 ? 2 : displayNights.length > 30 ? 4 : 7;
  const labelCount = Math.min(6, displayNights.length);
  const labelStep = Math.max(1, Math.ceil(Math.max(0, displayNights.length - 1) / Math.max(1, labelCount - 1)));
  const labelIndexes = new Set<number>();
  for (let i = 0; i < displayNights.length; i += labelStep) labelIndexes.add(i);
  if (displayNights.length) labelIndexes.add(displayNights.length - 1);

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
        <div style={{ color: "var(--faint)", fontSize: 12 }}>{displayNights.reduce((sum, night) => sum + (night.nights ?? 1), 0)} nights</div>
      </div>

      <div style={{ display: "flex", flexWrap: "wrap", gap: "8px 16px", marginTop: 18, color: "var(--muted)", fontSize: 12 }}>
        {STAGES.map((stage) => (
          <div key={stage.key} style={{ display: "flex", alignItems: "center", gap: 6 }}>
            <span aria-hidden="true" style={{ width: 9, height: 9, borderRadius: 3, background: stage.color }} />
            {stage.label}
          </div>
        ))}
        <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
          <span aria-hidden="true" style={{ width: 14, height: 2, borderRadius: 2, background: "var(--fg)" }} />
          Total sleep
        </div>
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

        <div style={{ minWidth: 0, width: "100%" }}>
          <div style={{ width: "100%", paddingBottom: 2 }}>
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

              {displayNights.length > 0 && (
                <svg
                  aria-label="Total sleep duration"
                  role="img"
                  viewBox={`0 0 100 ${chartHeight}`}
                  preserveAspectRatio="none"
                  style={{
                    position: "absolute",
                    inset: 0,
                    width: "100%",
                    height: "100%",
                    pointerEvents: "none",
                    overflow: "visible",
                  }}
                >
                  <polyline
                    fill="none"
                    stroke="var(--fg)"
                    strokeWidth="1.5"
                    vectorEffect="non-scaling-stroke"
                    strokeLinecap="round"
                    strokeLinejoin="round"
                    points={displayNights
                      .map((night, index) => {
                        const x = displayNights.length === 1
                          ? 50
                          : (index / (displayNights.length - 1)) * 100;
                        const y = chartHeight - (Math.min(axisMax, Math.max(0, night.asleepMinutes)) / axisMax) * chartHeight;
                        return `${x},${y}`;
                      })
                      .join(" ")}
                  />
                  {displayNights.length <= 90 && displayNights.map((night, index) => {
                    const x = displayNights.length === 1
                      ? 50
                      : (index / (displayNights.length - 1)) * 100;
                    const y = chartHeight - (Math.min(axisMax, Math.max(0, night.asleepMinutes)) / axisMax) * chartHeight;
                    return (
                      <circle
                        key={night.date}
                        cx={x}
                        cy={y}
                        r="2"
                        vectorEffect="non-scaling-stroke"
                        fill="var(--fg)"
                      />
                    );
                  })}
                </svg>
              )}

              {displayNights.map((night) => {
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
                      width: 0,
                      height: Math.max(2, barHeight),
                      flex: "1 1 0",
                      minWidth: 2,
                      display: "flex",
                      flexDirection: "column",
                      justifyContent: "flex-end",
                      overflow: "hidden",
                      borderRadius: "5px 5px 2px 2px",
                      background: "var(--border)",
                    }}
                    title={`${formatSleepPeriodLabel(night.date, interval)} · ${night.nights ?? 1} ${(night.nights ?? 1) === 1 ? "night" : "nights"} · ${hoursAndMinutes(night.asleepMinutes)} asleep · ${hoursAndMinutes(night.inBedMinutes)} in bed`}
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
                          title={`${formatSleepPeriodLabel(night.date, interval)} — ${stage.label}: ${hoursAndMinutes(minutes)} · ${night.nights ?? 1} ${(night.nights ?? 1) === 1 ? "night" : "nights"}`}
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
              {displayNights.map((night, index) => (
                <div
                  key={night.date}
                  style={{
                    width: 0,
                    flex: "1 1 0",
                    minWidth: 2,
                    textAlign: "center",
                    color: "var(--muted)",
                    fontSize: 10,
                    whiteSpace: "nowrap",
                  }}
                >
                  {labelIndexes.has(index) ? formatSleepPeriodLabel(night.date, interval) : ""}
                </div>
              ))}
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}
