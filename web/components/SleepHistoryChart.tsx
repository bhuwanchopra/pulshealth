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

  return (
    <section className="panel" style={{ padding: 20 }}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline", gap: 16 }}>
        <div>
          <div className="eyebrow" style={{ color: "var(--muted)" }}>History</div>
          <h2 style={{ margin: "5px 0 0", fontSize: 20 }}>Sleep stages</h2>
          <div style={{ color: "var(--muted)", fontSize: 13, marginTop: 5 }}>
            Each bar is one night, with stages stacked by duration.
          </div>
        </div>
        <div style={{ color: "var(--faint)", fontSize: 12 }}>14 nights</div>
      </div>

      <div
        style={{
          display: "flex",
          flexWrap: "wrap",
          gap: "8px 16px",
          marginTop: 18,
          color: "var(--muted)",
          fontSize: 12,
        }}
      >
        {STAGES.map((stage) => (
          <div key={stage.key} style={{ display: "flex", alignItems: "center", gap: 6 }}>
            <span
              aria-hidden="true"
              style={{
                width: 9,
                height: 9,
                borderRadius: 3,
                background: stage.color,
              }}
            />
            {stage.label}
          </div>
        ))}
      </div>

      <div
        style={{
          display: "grid",
          gridTemplateColumns: "34px minmax(0, 1fr)",
          gap: 10,
          marginTop: 18,
        }}
      >
        <div
          style={{
            position: "relative",
            height: 260,
            color: "var(--faint)",
            fontSize: 10,
          }}
        >
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

        <div style={{ position: "relative", minWidth: 0 }}>
          <div
            aria-hidden="true"
            style={{
              position: "absolute",
              inset: 0,
              pointerEvents: "none",
              backgroundImage: `linear-gradient(to top, transparent calc(100% - 1px), var(--border) calc(100% - 1px))`,
              backgroundSize: `100% ${(axisStep / axisMax) * 100}%`,
              opacity: 0.65,
            }}
          />

          <div
            style={{
              position: "relative",
              height: 260,
              display: "grid",
              gridTemplateColumns: `repeat(${nights.length}, minmax(14px, 1fr))`,
              alignItems: "end",
              gap: nights.length > 10 ? 5 : 8,
              padding: "0 2px",
            }}
          >
            {nights.map((night) => {
              const segments = STAGES.map((stage) => ({
                ...stage,
                minutes: Math.max(0, night[stage.key]),
              })).filter((stage) => stage.minutes > 0);

              return (
                <div
                  key={night.date}
                  style={{
                    height: `${(Math.min(axisMax, Math.max(0, night.inBedMinutes)) / axisMax) * 100}%`,
                    minHeight: 2,
                    display: "flex",
                    flexDirection: "column",
                    justifyContent: "flex-start",
                    overflow: "hidden",
                    borderRadius: "5px 5px 2px 2px",
                    background: "var(--border)",
                  }}
                  title={`${formatDate(night.date)} · ${hoursAndMinutes(night.asleepMinutes)} asleep · ${hoursAndMinutes(night.inBedMinutes)} in bed`}
                >
                  {segments.map((segment) => (
                    <div
                      key={segment.key}
                      style={{
                        height: `${(segment.minutes / Math.max(1, night.inBedMinutes)) * 100}%`,
                        minHeight: segment.minutes > 0 ? 1 : 0,
                        background: segment.color,
                        flexShrink: 0,
                      }}
                      title={`${segment.label}: ${hoursAndMinutes(segment.minutes)}`}
                    />
                  ))}
                </div>
              );
            })}
          </div>

          <div
            style={{
              display: "grid",
              gridTemplateColumns: `repeat(${nights.length}, minmax(14px, 1fr))`,
              gap: nights.length > 10 ? 5 : 8,
              padding: "8px 2px 0",
              borderTop: "1px solid var(--border)",
            }}
          >
            {nights.map((night) => (
              <div
                key={night.date}
                style={{
                  minWidth: 0,
                  overflow: "hidden",
                  textAlign: "center",
                  color: "var(--muted)",
                  fontSize: 10,
                  whiteSpace: "nowrap",
                }}
              >
                {formatDate(night.date)}
              </div>
            ))}
          </div>
        </div>
      </div>
    </section>
  );
}
