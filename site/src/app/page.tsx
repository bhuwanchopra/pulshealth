import Image from "next/image";
import Link from "next/link";
import {
  ArrowRight,
  BookOpen,
  Briefcase,
  Bot,
  Check,
  Database,
  FileCode2,
  FileSpreadsheet,
  LayoutDashboard,
  Lock,
  Minus,
  PenLine,
  QrCode,
  Smartphone,
  Star,
  Terminal,
} from "lucide-react";
import { GitHubIcon } from "@/components/brand-icons";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { AppStoreBadge } from "@/components/app-store-badge";
import { FollowProject } from "@/components/follow-project";
import { faq } from "@/lib/faq";
import { GITHUB_URL, formatStars, getRepoStats } from "@/lib/github";

const BLOB = `${GITHUB_URL}/blob/main`;

const steps = [
  {
    n: "1",
    title: "Set up your database",
    icon: Terminal,
    body: "One script on any Docker host. It generates every secret, starts PostgreSQL with ingest, the API, Grafana and the viewer, and prints a pairing code.",
  },
  {
    n: "2",
    title: "Scan to pair",
    icon: QrCode,
    body: "Install the free app and scan the code from its Sync tab. Pick the Apple Health types you want and a start date. The full history goes first; then it keeps up on its own.",
  },
  {
    n: "3",
    title: "Use the data",
    icon: Database,
    body: "It is plain PostgreSQL. Query it with SQL, open the dashboards, export CSV or JSONL, or point Claude at the read-only MCP server and ask.",
  },
];

const pieces = [
  {
    title: "iOS app",
    href: "/ios",
    icon: Smartphone,
    description: "Reads Apple Health read-only. Explore and export it on the phone, or stream every sample to your database: full backfill first, then background sync. 81 types, workouts with GPS, activity rings.",
  },
  {
    title: "PostgreSQL + TimescaleDB",
    href: "/server",
    icon: Database,
    description: "Samples land in hypertables with compression on older chunks. Migrations run automatically on every start. Backups are built in but off by default.",
  },
  {
    title: "Grafana and a web viewer",
    href: "/server",
    icon: LayoutDashboard,
    description: "Provisioned dashboards for the health data and for ingest health, plus a Next.js viewer over the same database. Optional password, no account.",
  },
  {
    title: "Open wire protocol",
    href: "/docs/protocol",
    icon: FileCode2,
    description: "Gzip NDJSON over HTTPS, a JSON Schema per line type, canonical units, a fixture corpus and a Python reference receiver. Or write your own backend.",
  },
  {
    title: "MCP server for AI",
    href: "/docs/ai",
    icon: Bot,
    description: "Read-only, over the product API, so Claude, Claude Code or Cursor can answer questions from your own daily metrics, rings, workouts and sleep.",
  },
  {
    title: "CSV and JSONL export",
    href: "/docs/export",
    icon: FileSpreadsheet,
    description: "The product API streams any dataset out, and a small CLI wraps it. The quickest route to a spreadsheet or a notebook.",
  },
];

const claims = [
  {
    title: "The developer never sees your data",
    body: "There is no PulsHealth service and no account. The app posts to the one URL you enter and nowhere else.",
    check: { label: "Transport/", href: `${GITHUB_URL}/tree/main/PulsHealthSync/Sources/PulsHealthSync/Transport` },
  },
  {
    title: "Zero third-party dependencies in the app",
    body: "No analytics SDK, no crash reporter, no ad library. The Swift package and the app depend on Apple frameworks and nothing else.",
    check: { label: "Package.swift", href: `${BLOB}/PulsHealthSync/Package.swift` },
  },
  {
    title: "Read-only, in the code",
    body: "The app asks HealthKit for read permission only and never writes, edits or deletes. The usage strings say so, and the code shows it.",
    check: { label: "HealthSyncEngine.swift", href: `${BLOB}/PulsHealthSync/Sources/PulsHealthSync/Engine/HealthSyncEngine.swift` },
  },
];

type Cell = boolean | string;
const comparison: { name: string; href?: string; cells: Cell[] }[] = [
  { name: "PulsHealth", cells: [true, true, "Apache-2.0", "Your Postgres", true, true, "Free"] },
  { name: "Health Auto Export", href: "https://www.healthyapps.dev/", cells: [false, "Community receivers", "Closed", "Your endpoint, Drive, MQTT…", "Community-documented", false, "Subscription"] },
  { name: "HealthSave", href: "https://healthsave.app/", cells: [false, "Source-available", "Elastic 2.0", "Your TimescaleDB", false, false, "One-time"] },
  { name: "FreeReps", href: "https://freereps.meltforce.org/", cells: [true, true, "MIT", "Your server (Tailscale)", false, true, "Free"] },
  { name: "Apple's export", cells: [false, false, "—", "A zip of XML", false, false, "Free"] },
];
const comparisonColumns = ["Open-source app", "Open-source backend", "License", "Where data lives", "Wire format specified", "AI assistant access", "Price"];

function CellValue({ value }: { value: Cell }) {
  if (value === true) return <Check className="mx-auto h-4 w-4 text-brand" aria-label="Yes" />;
  if (value === false) return <Minus className="mx-auto h-4 w-4 text-muted-foreground/60" aria-label="No" />;
  return <span className="text-muted-foreground">{value}</span>;
}

export default async function HomePage() {
  const { stars } = await getRepoStats();
  const starLabel = formatStars(stars);
  const homeFaq = faq.filter((f) => f.home);

  return (
    <main className="flex min-h-screen flex-col">
      {/* Hero */}
      <section className="w-full border-b bg-gradient-to-b from-background to-muted/40 pt-20 pb-16">
        <div className="container mx-auto flex max-w-7xl flex-col items-center space-y-6 px-4 text-center">
          <Badge variant="outline" className="rounded-full bg-background/60 px-4 py-1 text-sm backdrop-blur-sm">
            Open source &middot; Apache-2.0 &middot; Free on the App Store
          </Badge>

          <h1 className="max-w-4xl text-4xl font-bold tracking-tight text-foreground text-balance md:text-6xl">
            Apple Health, in a database <span className="text-brand">you</span> run.
          </h1>

          <p className="max-w-2xl text-lg leading-relaxed text-muted-foreground text-pretty md:text-xl">
            A free iPhone app to explore and export your Apple Health data, and to sync 80
            HealthKit types into your own database. Query it in SQL, chart it in Grafana, or ask
            Claude about it. There is no PulsHealth service in the middle.
          </p>

          <div className="flex flex-col items-center gap-4 pt-2 sm:flex-row">
            <AppStoreBadge />
            <Button asChild size="lg">
              <Link href="/server">
                <Database className="mr-2 h-4 w-4" />
                Set up your database
              </Link>
            </Button>
          </div>

          <ul className="flex flex-wrap items-center justify-center gap-x-5 gap-y-2 pt-2 text-sm text-muted-foreground">
            <li>No telemetry</li>
            <li>No account</li>
            <li>Read-only HealthKit access</li>
            <li>Zero dependencies in the app</li>
            <li>
              <a href={GITHUB_URL} target="_blank" rel="noopener noreferrer" className="inline-flex items-center gap-1 hover:text-foreground">
                <Star className="h-3.5 w-3.5" aria-hidden />
                {starLabel ? `${starLabel} on GitHub` : "Source on GitHub"}
              </a>
            </li>
          </ul>
        </div>

        {/* Product shot */}
        <div className="container mx-auto mt-14 max-w-6xl px-4">
          <figure className="overflow-hidden rounded-xl border bg-[#0b0b0c] shadow-2xl shadow-black/20">
            <div className="flex items-center gap-1.5 border-b border-white/10 px-4 py-2.5">
              <span className="h-2.5 w-2.5 rounded-full bg-white/15" />
              <span className="h-2.5 w-2.5 rounded-full bg-white/15" />
              <span className="h-2.5 w-2.5 rounded-full bg-white/15" />
              <span className="ml-3 truncate font-mono text-[11px] text-white/40">https://health.example.net</span>
            </div>
            <Image
              src="/screenshots/viewer-today.webp"
              alt="The PulsHealth web viewer showing today's activity rings, highlight tiles for steps, energy, resting heart rate, sleep, HRV, distance, VO2 max and body weight, and recent workouts."
              width={1440}
              height={900}
              priority
              className="w-full"
            />
            <figcaption className="border-t border-white/10 px-4 py-2 text-xs text-white/50">
              The web viewer that ships with the self-hosted stack, against demo data.
            </figcaption>
          </figure>
        </div>
      </section>

      {/* Three steps */}
      <section className="container mx-auto max-w-7xl px-4 py-24">
        <div className="mb-12 text-center">
          <h2 className="mb-4 text-3xl font-bold tracking-tight">How it works</h2>
          <p className="mx-auto max-w-2xl text-lg text-muted-foreground">
            Apple Health keeps years of your data behind an API only apps can read. PulsHealth
            moves it into a database you own.
          </p>
        </div>

        <div className="grid gap-6 md:grid-cols-3">
          {steps.map((step) => (
            <Card key={step.n} className="h-full">
              <CardHeader>
                <div className="mb-3 flex items-center gap-3">
                  <span className="flex h-8 w-8 items-center justify-center rounded-full bg-brand font-mono text-sm font-semibold text-brand-foreground">
                    {step.n}
                  </span>
                  <step.icon className="h-5 w-5 text-brand" />
                </div>
                <CardTitle className="text-xl">{step.title}</CardTitle>
                <CardDescription className="text-base">{step.body}</CardDescription>
              </CardHeader>
            </Card>
          ))}
        </div>

        <div className="mx-auto mt-8 max-w-3xl">
          <div className="overflow-x-auto rounded-lg border bg-muted/30 p-5">
            <pre className="font-mono text-sm leading-relaxed text-muted-foreground">
              <code>{`git clone https://github.com/PulsHealth/pulshealth.git
cd pulshealth
scripts/bootstrap.sh --time-zone Europe/Berlin`}</code>
            </pre>
          </div>
          <p className="mt-3 text-center text-sm text-muted-foreground">
            Pass the time zone your phone lives in. The script pulls the published images; add{" "}
            <code>--build</code> to compile them from the checkout instead.
          </p>
          <div className="mt-6 flex flex-col justify-center gap-3 sm:flex-row">
            <Button asChild variant="outline">
              <Link href="/server">
                The self-hosted stack, in detail
                <ArrowRight className="ml-2 h-4 w-4" />
              </Link>
            </Button>
            <Button asChild variant="outline">
              <Link href="/docs">
                Documentation
                <ArrowRight className="ml-2 h-4 w-4" />
              </Link>
            </Button>
          </div>
        </div>
      </section>

      {/* What is in the box */}
      <section className="border-y bg-muted/30">
        <div className="container mx-auto max-w-7xl px-4 py-24">
          <div className="mb-12 text-center">
            <h2 className="mb-4 text-3xl font-bold tracking-tight">What is included</h2>
            <p className="mx-auto max-w-2xl text-lg text-muted-foreground">
              All of it is in one Apache-2.0 repository. There are no paid tiers.
            </p>
          </div>

          <div className="grid gap-6 md:grid-cols-2 lg:grid-cols-3">
            {pieces.map((piece) => (
              <Link key={piece.title} href={piece.href} className="group">
                <Card className="h-full transition-all duration-200 hover:border-brand/40 hover:shadow-lg">
                  <CardHeader>
                    <div className="mb-4 w-fit rounded-xl bg-brand-muted p-3 text-brand">
                      <piece.icon className="h-6 w-6" />
                    </div>
                    <CardTitle className="text-xl transition-colors group-hover:text-brand">
                      {piece.title}
                    </CardTitle>
                    <CardDescription className="text-base">{piece.description}</CardDescription>
                  </CardHeader>
                  <CardContent>
                    <span className="inline-flex items-center text-sm font-medium text-brand">
                      Learn more <ArrowRight className="ml-1 h-4 w-4 transition-transform group-hover:translate-x-0.5" />
                    </span>
                  </CardContent>
                </Card>
              </Link>
            ))}
          </div>

          <figure className="mx-auto mt-12 max-w-4xl overflow-hidden rounded-xl border bg-[#0b0b0c] shadow-xl shadow-black/10">
            <Image
              src="/screenshots/viewer-workouts.webp"
              alt="The web viewer's workouts page: session count, total time, energy and distance, then a list of workouts with duration, calories and distance."
              width={1440}
              height={900}
              className="w-full"
            />
            <figcaption className="border-t border-white/10 px-4 py-2 text-xs text-white/50">
              Workouts in the web viewer. Grafana dashboards cover the same data and ingest health.
            </figcaption>
          </figure>
        </div>
      </section>

      {/* Why self-hosted: checkable claims */}
      <section className="container mx-auto max-w-7xl px-4 py-24">
        <div className="mb-12 text-center">
          <h2 className="mb-4 text-3xl font-bold tracking-tight">Privacy, with the code to show for it</h2>
          <p className="mx-auto max-w-2xl text-lg text-muted-foreground">
            Health data is personal. Each claim below links to the code behind it.
          </p>
        </div>

        <div className="grid gap-8 md:grid-cols-3">
          {claims.map((claim) => (
            <div key={claim.title} className="rounded-xl border bg-card p-6">
              <div className="mb-4 w-fit rounded-xl bg-brand-muted p-3 text-brand">
                <Lock className="h-6 w-6" />
              </div>
              <h3 className="mb-2 text-lg font-semibold">{claim.title}</h3>
              <p className="mb-4 text-muted-foreground">{claim.body}</p>
              <a
                href={claim.check.href}
                target="_blank"
                rel="noopener noreferrer"
                className="inline-flex items-center gap-1.5 font-mono text-xs text-brand hover:underline"
              >
                <GitHubIcon className="h-3.5 w-3.5" />
                check: {claim.check.label}
              </a>
            </div>
          ))}
        </div>
      </section>

      {/* Comparison */}
      <section className="border-y bg-muted/30">
        <div className="container mx-auto max-w-7xl px-4 py-24">
          <div className="mb-10 text-center">
            <h2 className="mb-4 text-3xl font-bold tracking-tight">Compared with the alternatives</h2>
            <p className="mx-auto max-w-2xl text-lg text-muted-foreground">
              Other ways to get Apple Health out of the phone, and where they differ.
            </p>
          </div>

          <div className="overflow-x-auto rounded-xl border bg-card">
            <table className="w-full min-w-[820px] text-sm">
              <thead>
                <tr className="border-b bg-muted/40 text-left">
                  <th className="px-4 py-3 font-semibold">&nbsp;</th>
                  {comparisonColumns.map((col) => (
                    <th key={col} className="px-4 py-3 text-center font-semibold">{col}</th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {comparison.map((row) => (
                  <tr key={row.name} className={`border-b last:border-0 ${row.name === "PulsHealth" ? "bg-brand-muted/40" : ""}`}>
                    <th scope="row" className="px-4 py-3 text-left font-medium">
                      {row.href ? (
                        <a href={row.href} target="_blank" rel="noopener noreferrer" className="hover:underline">
                          {row.name}
                        </a>
                      ) : (
                        row.name
                      )}
                    </th>
                    {row.cells.map((cell, i) => (
                      <td key={i} className="px-4 py-3 text-center">
                        <CellValue value={cell} />
                      </td>
                    ))}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <p className="mt-4 text-center text-xs text-muted-foreground">
            Checked in September 2026 against each project&apos;s public site. If something here is
            out of date,{" "}
            <a href={`${GITHUB_URL}/issues`} target="_blank" rel="noopener noreferrer" className="underline underline-offset-4 hover:text-foreground">
              open an issue
            </a>{" "}
            and it will be corrected.
          </p>
        </div>
      </section>

      {/* Reference material */}
      <section className="container mx-auto max-w-7xl px-4 py-24">
        <div className="mx-auto grid max-w-4xl gap-6 md:grid-cols-2">
          <Link href="/knowledge-base" className="group">
            <Card className="h-full transition-all duration-200 hover:border-brand/40 hover:shadow-lg">
              <CardHeader>
                <div className="mb-4 w-fit rounded-xl bg-brand-muted p-3 text-brand">
                  <BookOpen className="h-6 w-6" />
                </div>
                <CardTitle className="transition-colors group-hover:text-brand">Knowledge base</CardTitle>
                <CardDescription className="text-base">
                  What each of the 178 Apple Health types measures: sampling, typical ranges, how
                  devices differ, and the limits of the number.
                </CardDescription>
              </CardHeader>
            </Card>
          </Link>
          <Link href="/blog" className="group">
            <Card className="h-full transition-all duration-200 hover:border-brand/40 hover:shadow-lg">
              <CardHeader>
                <div className="mb-4 w-fit rounded-xl bg-brand-muted p-3 text-brand">
                  <PenLine className="h-6 w-6" />
                </div>
                <CardTitle className="transition-colors group-hover:text-brand">Blog</CardTitle>
                <CardDescription className="text-base">
                  Posts about health metrics and the engineering of syncing them.
                </CardDescription>
              </CardHeader>
            </Card>
          </Link>
        </div>
      </section>

      {/* FAQ */}
      <section className="border-t bg-muted/30">
        <div className="container mx-auto max-w-3xl px-4 py-24">
          <h2 className="mb-8 text-center text-3xl font-bold tracking-tight">Common questions</h2>
          <div className="divide-y rounded-xl border bg-card">
            {homeFaq.map((item) => (
              <details key={item.q} className="group px-5 py-4">
                <summary className="flex cursor-pointer list-none items-center justify-between gap-4 font-medium">
                  {item.q}
                  <span className="font-mono text-muted-foreground transition-transform group-open:rotate-45">+</span>
                </summary>
                <p className="mt-3 text-muted-foreground text-pretty">{item.a}</p>
              </details>
            ))}
          </div>
          <p className="mt-6 text-center text-sm text-muted-foreground">
            More on the{" "}
            <Link href="/support" className="text-brand underline-offset-4 hover:underline">
              support page
            </Link>
            , including the iOS behaviours that look like bugs.
          </p>
        </div>
      </section>

      {/* Consulting */}
      <section className="border-t">
        <div className="container mx-auto max-w-7xl px-4 py-24">
          <div className="mx-auto grid max-w-5xl items-center gap-10 md:grid-cols-[1.2fr_1fr]">
            <div>
              <Badge variant="outline" className="mb-4">Consulting</Badge>
              <h2 className="mb-4 text-3xl font-bold tracking-tight">Consulting</h2>
              <p className="text-lg text-muted-foreground">
                Everything on this site is free. If you want help setting up the stack,
                connecting your data to AI tools, implementing the protocol against your own
                backend, or building on the data, I do that work.
              </p>
              <div className="mt-6 flex flex-col gap-3 sm:flex-row">
                <Button asChild size="lg">
                  <Link href="/consulting">
                    <Briefcase className="mr-2 h-4 w-4" />
                    Consulting
                  </Link>
                </Button>
                <Button asChild size="lg" variant="outline">
                  <a href="mailto:support@pulshealth.com">Email the maintainer</a>
                </Button>
              </div>
            </div>
            <ul className="space-y-3 rounded-xl border bg-card p-6 text-sm">
              {[
                "Get the self-hosted stack running, and keep it running",
                "Wire your health data into Claude, Cursor or ChatGPT",
                "Implement or review a Puls Sync Protocol receiver",
                "Dashboards, exports and analysis on your own data",
                "Health-data engineering beyond this project",
              ].map((item) => (
                <li key={item} className="flex items-start gap-3">
                  <Check className="mt-0.5 h-4 w-4 shrink-0 text-brand" />
                  <span className="text-muted-foreground">{item}</span>
                </li>
              ))}
            </ul>
          </div>
        </div>
      </section>

      <FollowProject />
    </main>
  );
}
