"use client";

import { useState } from "react";
import { usePathname, useRouter, useSearchParams } from "next/navigation";
import { RANGES, RANGE_ORDER } from "@/lib/metrics";
import type { RangeKey } from "@/lib/types";

function formatDate(date: Date): string {
  return date.toISOString().slice(0, 10);
}

function defaultFromDate(): string {
  const d = new Date();
  d.setFullYear(d.getFullYear() - 1);
  return formatDate(d);
}

function todayDate(): string {
  return formatDate(new Date());
}

export function RangeSelector({ value }: { value: RangeKey }) {
  const router = useRouter();
  const pathname = usePathname();
  const params = useSearchParams();

  const urlFrom = params.get("from") ?? "";
  const urlTo = params.get("to") ?? "";

  const [fromDate, setFromDate] = useState(urlFrom || defaultFromDate());
  const [toDate, setToDate] = useState(urlTo || todayDate());
  const [error, setError] = useState("");

  function navigate(next: URLSearchParams) {
    const query = next.toString();
    router.replace(query ? `${pathname}?${query}` : pathname, {
      scroll: false,
    });
  }

  function select(k: RangeKey) {
    const next = new URLSearchParams(params.toString());
    next.set("range", k);

    if (k !== "CUSTOM") {
      next.delete("from");
      next.delete("to");
      setError("");
    } else {
      if (!next.get("from")) {
        next.set("from", fromDate || defaultFromDate());
      }
      if (!next.get("to")) {
        next.set("to", toDate || todayDate());
      }
    }

    navigate(next);
  }

  function applyCustom() {
    setError("");

    if (!fromDate || !toDate) {
      setError("Select both dates.");
      return;
    }

    if (fromDate > toDate) {
      setError("From date must be on or before To date.");
      return;
    }

    const next = new URLSearchParams(params.toString());
    next.set("range", "CUSTOM");
    next.set("from", fromDate);
    next.set("to", toDate);

    navigate(next);
  }

  function resetCustom() {
    const from = defaultFromDate();
    const to = todayDate();

    setFromDate(from);
    setToDate(to);
    setError("");

    const next = new URLSearchParams(params.toString());
    next.set("range", "CUSTOM");
    next.set("from", from);
    next.set("to", to);

    navigate(next);
  }

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
      <div
        className="segmented"
        role="group"
        aria-label="Time range"
        style={{ flexWrap: "wrap" }}
      >
        {RANGE_ORDER.map((k) => {
          const label =
            k === "Y"
              ? "1Y"
              : k === "CUSTOM"
                ? "Custom"
                : RANGES[k].key;

          return (
            <button
              key={k}
              type="button"
              aria-pressed={value === k}
              aria-label={RANGES[k].label}
              data-active={value === k}
              onClick={() => select(k)}
            >
              {label}
            </button>
          );
        })}
      </div>

      {value === "CUSTOM" && (
        <div
          style={{
            display: "flex",
            alignItems: "flex-end",
            gap: 8,
            flexWrap: "wrap",
            justifyContent: "flex-end",
          }}
        >
          <label
            style={{
              display: "flex",
              flexDirection: "column",
              gap: 4,
              fontSize: 11,
              color: "var(--muted)",
            }}
          >
            <span>From</span>
            <input
              type="date"
              value={fromDate}
              max={toDate || undefined}
              onChange={(e) => setFromDate(e.target.value)}
              style={{
                height: 34,
                padding: "0 8px",
                borderRadius: 7,
                border: "1px solid var(--line)",
                background: "var(--panel)",
                color: "var(--fg)",
                font: "inherit",
                fontSize: 12,
              }}
            />
          </label>

          <label
            style={{
              display: "flex",
              flexDirection: "column",
              gap: 4,
              fontSize: 11,
              color: "var(--muted)",
            }}
          >
            <span>To</span>
            <input
              type="date"
              value={toDate}
              min={fromDate || undefined}
              max={todayDate()}
              onChange={(e) => setToDate(e.target.value)}
              style={{
                height: 34,
                padding: "0 8px",
                borderRadius: 7,
                border: "1px solid var(--line)",
                background: "var(--panel)",
                color: "var(--fg)",
                font: "inherit",
                fontSize: 12,
              }}
            />
          </label>

          <button
            type="button"
            onClick={applyCustom}
            style={{
              height: 34,
              padding: "0 12px",
              borderRadius: 7,
              border: "1px solid var(--line)",
              background: "var(--accent)",
              color: "white",
              font: "inherit",
              fontSize: 12,
              fontWeight: 600,
              cursor: "pointer",
            }}
          >
            Apply
          </button>

          <button
            type="button"
            onClick={resetCustom}
            style={{
              height: 34,
              padding: "0 12px",
              borderRadius: 7,
              border: "1px solid var(--line)",
              background: "var(--panel)",
              color: "var(--fg-soft)",
              font: "inherit",
              fontSize: 12,
              cursor: "pointer",
            }}
          >
            Reset
          </button>

          {error && (
            <div
              role="alert"
              style={{
                width: "100%",
                textAlign: "right",
                fontSize: 11,
                color: "var(--danger, #ef4444)",
              }}
            >
              {error}
            </div>
          )}
        </div>
      )}
    </div>
  );
}
