import type { Group } from "@/lib/catalog";

type P = { className?: string; size?: number; style?: React.CSSProperties };

function Svg({ className, size = 18, style, children }: P & { children: React.ReactNode }) {
  return (
    <svg
      className={className}
      style={style}
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.6}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      {children}
    </svg>
  );
}

export const HomeIcon = (p: P) => (
  <Svg {...p}>
    <path d="M3 10.5 12 3l9 7.5" />
    <path d="M5 9.5V21h14V9.5" />
  </Svg>
);
export const WorkoutIcon = (p: P) => (
  <Svg {...p}>
    <path d="M6.5 6.5 17.5 17.5" />
    <rect x="2.2" y="8.4" width="3.2" height="7.2" rx="1" transform="rotate(-45 3.8 12)" />
    <rect x="18.6" y="8.4" width="3.2" height="7.2" rx="1" transform="rotate(-45 20.2 12)" />
  </Svg>
);
export const GridIcon = (p: P) => (
  <Svg {...p}>
    <rect x="3" y="3" width="7" height="7" rx="1.5" />
    <rect x="14" y="3" width="7" height="7" rx="1.5" />
    <rect x="3" y="14" width="7" height="7" rx="1.5" />
    <rect x="14" y="14" width="7" height="7" rx="1.5" />
  </Svg>
);
export const SunIcon = (p: P) => (
  <Svg {...p}>
    <circle cx="12" cy="12" r="4" />
    <path d="M12 2v2M12 20v2M2 12h2M20 12h2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M19.1 4.9l-1.4 1.4M6.3 17.7l-1.4 1.4" />
  </Svg>
);
export const MoonIcon = (p: P) => (
  <Svg {...p}>
    <path d="M21 12.8A8.5 8.5 0 1 1 11.2 3a6.5 6.5 0 0 0 9.8 9.8Z" />
  </Svg>
);
export const ArrowUp = (p: P) => (
  <Svg {...p}>
    <path d="M12 19V5M6 11l6-6 6 6" />
  </Svg>
);
export const ArrowDown = (p: P) => (
  <Svg {...p}>
    <path d="M12 5v14M6 13l6 6 6-6" />
  </Svg>
);
export const ChevronRight = (p: P) => (
  <Svg {...p}>
    <path d="m9 6 6 6-6 6" />
  </Svg>
);
export const UserIcon = (p: P) => (
  <Svg {...p}>
    <circle cx="12" cy="8" r="4" />
    <path d="M4 21a8 8 0 0 1 16 0" />
  </Svg>
);

export const SignOutIcon = (p: P) => (
  <Svg {...p}>
    <path d="M15 4h3a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2h-3" />
    <path d="M10 17 5 12l5-5M5 12h11" />
  </Svg>
);

export const SettingsIcon = (p: P) => (
  <Svg {...p}>
    <circle cx="12" cy="12" r="3" />
    <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z" />
  </Svg>
);

// ── category glyphs ───────────────────────────────────────────────────────
const Activity = (p: P) => (
  <Svg {...p}>
    <path d="M3 12h3.5l2-6 3.5 13 2.5-9 1.6 4H21" />
  </Svg>
);
const Heart = (p: P) => (
  <Svg {...p}>
    <path d="M12 20s-7-4.4-9.3-8.5C1.2 8.8 2.6 5.5 5.8 5.5c2 0 3.2 1.2 4.2 2.5 1-1.3 2.2-2.5 4.2-2.5 3.2 0 4.6 3.3 3.1 6C19 15.6 12 20 12 20Z" />
  </Svg>
);
const Body = (p: P) => (
  <Svg {...p}>
    <circle cx="12" cy="5" r="2.4" />
    <path d="M12 7.6v7m0 0-3.5 5.4M12 14.6l3.5 5.4M6.5 10.5 12 9.2l5.5 1.3" />
  </Svg>
);
const Lungs = (p: P) => (
  <Svg {...p}>
    <path d="M12 3v8" />
    <path d="M9 7c0 0-3 1-3 5s-.5 7 2 7 2.2-2 2.2-4V9.5C10.2 8 9 7 9 7Z" />
    <path d="M15 7c0 0 3 1 3 5s.5 7-2 7-2.2-2-2.2-4V9.5C13.8 8 15 7 15 7Z" />
  </Svg>
);
const Moon = (p: P) => (
  <Svg {...p}>
    <path d="M21 12.8A8.5 8.5 0 1 1 11.2 3a6.5 6.5 0 0 0 9.8 9.8Z" />
  </Svg>
);
const Nutrition = (p: P) => (
  <Svg {...p}>
    <path d="M6 3v7a2.5 2.5 0 0 0 5 0V3M8.5 3v18" />
    <path d="M17 3c-1.6 0-2.5 2-2.5 5s.9 4 2.5 4v9" />
  </Svg>
);
const Vitals = (p: P) => (
  <Svg {...p}>
    <path d="M12 3.5c3.5 4 5.5 6.4 5.5 9.3A5.5 5.5 0 0 1 6.5 12.8c0-2.9 2-5.3 5.5-9.3Z" />
  </Svg>
);
const Dumbbell = (p: P) => (
  <Svg {...p}>
    <path d="M6.5 6.5 17.5 17.5" />
    <rect x="2.2" y="8.4" width="3.2" height="7.2" rx="1" transform="rotate(-45 3.8 12)" />
    <rect x="18.6" y="8.4" width="3.2" height="7.2" rx="1" transform="rotate(-45 20.2 12)" />
  </Svg>
);
const Sparkle = (p: P) => (
  <Svg {...p}>
    <path d="M12 3v18M3 12h18M6 6l12 12M18 6 6 18" />
  </Svg>
);

const GROUP_ICONS: Record<Group, (p: P) => React.ReactNode> = {
  activity: Activity,
  heart: Heart,
  body: Body,
  respiratory: Lungs,
  sleep: Moon,
  nutrition: Nutrition,
  vitals: Vitals,
  workouts: Dumbbell,
  other: Sparkle,
};

export function GroupIcon({ group, ...p }: P & { group: Group }) {
  const C = GROUP_ICONS[group];
  return <C {...p} />;
}
