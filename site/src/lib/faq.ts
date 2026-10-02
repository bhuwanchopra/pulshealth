/**
 * Ported from the repository README's FAQ, which is the source of truth; keep
 * the two in step when either changes. The support page renders all of it and
 * the home page a subset.
 */
export interface FaqItem {
  q: string;
  a: string;
  /** Show on the home page as well as the support page. */
  home?: boolean;
}

export const faq: FaqItem[] = [
  {
    q: "Is the app really free? What is the catch?",
    a: "Free, no in-app purchases, no account. The catch is that you run the database yourself; there is no PulsHealth service to send data to. The open-source stack sets one up with one command on any Docker host, and exploring and exporting work without one.",
    home: true,
  },
  {
    q: "Do I need a domain, a VPN or Tailscale?",
    a: "No. On the same Wi-Fi the phone can sync to your database over plain HTTP; the app allows that for local-network addresses only. From anywhere else you need HTTPS, which means a TLS proxy or a VPN such as Tailscale in front of the ingest port.",
    home: true,
  },
  {
    q: "Where does my data go?",
    a: "To the database URL you enter in the app, and nowhere else. The developer runs no server, has no account system and receives nothing. The app has zero third-party dependencies and no analytics SDK.",
    home: true,
  },
  {
    q: "Can I sync to a database I already have?",
    a: "Yes, through a receiver for the Puls Sync Protocol v1, the wire format the app speaks. It is specified with a JSON Schema per line type, a fixture corpus, a conformance checker and a complete receiver in one Python file. Anything that speaks it is a valid destination.",
    home: true,
  },
  {
    q: "How long does a first backfill take?",
    a: "It depends on the phone, not the database, because reading HealthKit is the slow part. The app includes a benchmark that reads real data without uploading it, so you can measure your own device first. Progress is saved after every confirmed batch, so you can interrupt it safely.",
    home: true,
  },
  {
    q: "Does it write anything into Apple Health?",
    a: "No. The app requests read access only, and its usage strings say so.",
    home: true,
  },
  {
    q: "My Watch data arrives minutes or hours late.",
    a: "Watch to iPhone HealthKit transfer is scheduled by watchOS and cannot be forced by any app. Opening PulsHealth, or putting the Watch on its charger, usually prompts it. Once the data is on the phone it syncs normally.",
  },
  {
    q: "Steps, active energy and distance lag by up to an hour, while workouts appear in seconds.",
    a: "iOS throttles \"immediate\" background delivery for those high-frequency types to roughly hourly, without saying so, and it is not configurable. Anything else you record on the phone, and every foreground open, syncs right away.",
  },
  {
    q: "Nothing synced overnight.",
    a: "While the phone is locked, HealthKit is unreadable, and iOS prefers to run background processing when the device is idle, which is to say locked, overnight. PulsHealth detects this, records the wake as skipped (locked) on the Background Activity screen instead of claiming a sync, and catches up at the next unlock or app open.",
  },
  {
    q: "I swiped the app away and it stopped syncing.",
    a: "iOS does not wake force-quit apps for background delivery or scheduled tasks. Open the app again and it resumes; leaving it in the app switcher is enough.",
  },
  {
    q: "Blood pressure never shows up in the permission sheet.",
    a: "On iOS 26 the Health permission sheet silently omits blood pressure systolic and diastolic, so they can never be granted from within the app (Apple Feedback FB22735935; iOS 27 fixes it). Grant them yourself in Settings, Privacy & Security, Health, PulsHealth. The app shows a hint when it detects the situation and backfills the full history once access exists.",
  },
  {
    q: "Daily step totals in the database are higher than the Health app shows.",
    a: "The iPhone and the Watch both record steps, and a naive sum of raw samples counts both. Use the metric_daily view, or the app's on-device aggregate series, which HealthKit already de-duplicates, instead of summing quantity_samples. The database guide explains the query patterns.",
  },
];
