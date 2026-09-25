import Link from "next/link";
import { ArrowRight, BookOpen, Bot, Code2, Database, Globe, HardDriveDownload, LayoutDashboard, LineChart, Package, Plug, Server, ShieldCheck, Smartphone, Terminal } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";

const GITHUB = "https://github.com/PulsHealth/pulshealth";

export const metadata = {
  title: "The Self-Hosted PulsHealth Stack",
  description: "The open-source reference backend for PulsHealth: PostgreSQL 17 with TimescaleDB, a Go ingest API, a read-only product API, Grafana, a web viewer and an MCP server, all via Docker Compose on a machine you own.",
  alternates: {
    canonical: '/sync/',
  },
};

const services = [
  {
    title: "PostgreSQL 17 + TimescaleDB",
    description: "Samples land in hypertables, with columnstore compression on older chunks. Schema migrations are applied by a migrate service before anything else starts, so an upgrade is a pull and a restart.",
    icon: Database,
  },
  {
    title: "Ingest API (Go)",
    description: "The one service designed to face the network. Bearer authentication, gzip NDJSON bodies, inserts that deduplicate by sample UUID, per-IP rate limiting on failed authentications, and structured per-batch logs.",
    icon: Server,
  },
  {
    title: "Product API (Go)",
    description: "Read-only, with an OpenAPI 3.1 document. Deduplicated daily metrics, workouts and their series, activity rings, latest readings, and a streaming export endpoint.",
    icon: Code2,
  },
  {
    title: "Grafana",
    description: "Provisioned dashboards for the health data itself and for ingest health — batches per hour, rows per day, per-type totals, last-batch age — with alert rules already defined.",
    icon: LineChart,
  },
  {
    title: "Web Viewer",
    description: "A Next.js viewer over the same database: activity rings, trends, workouts and the type catalog. Set a password and every page sits behind HTTP Basic; leave it unset and it is an open read-only page.",
    icon: LayoutDashboard,
  },
  {
    title: "MCP Server",
    description: "Read-only, talking only to the product API, so Claude, Claude Code or Cursor can answer questions from your data. Run it as a local binary or as a remote connector over HTTPS.",
    icon: Bot,
  },
];

export default function SyncPage() {
  return (
    <main className="flex min-h-screen flex-col">
      {/* Hero Section */}
      <section className="w-full bg-gradient-to-b from-white to-zinc-50 dark:from-zinc-950 dark:to-zinc-900 pt-20 pb-32 border-b">
        <div className="container mx-auto max-w-7xl px-4 flex flex-col items-center text-center space-y-8">
          <Badge variant="outline" className="px-4 py-1 text-sm rounded-full border-zinc-200 dark:border-zinc-800 bg-white/50 dark:bg-zinc-900/50 backdrop-blur-sm">
            Docker Compose &middot; Apache-2.0
          </Badge>

          <h1 className="text-4xl md:text-6xl font-bold tracking-tight text-zinc-900 dark:text-zinc-50 max-w-4xl">
            Your server, your{" "}
            <span className="text-brand">health database</span>
          </h1>

          <p className="text-lg md:text-xl text-zinc-500 max-w-2xl leading-relaxed">
            The reference backend the PulsHealth app syncs to. It runs on a home machine, a NAS, a
            Raspberry Pi, or a rented box — whichever you own. There is no hosted option and no
            managed tier, and that is deliberate.
          </p>

          <div className="flex flex-col sm:flex-row gap-4 pt-4">
            <Button asChild size="lg" className="bg-brand hover:bg-brand-dark text-brand-foreground">
              <Link href="/docs/self-hosting">
                <BookOpen className="mr-2 h-4 w-4" />
                Server Documentation
              </Link>
            </Button>
            <Button asChild variant="outline" size="lg">
              <Link href="/app">
                <Smartphone className="mr-2 h-4 w-4" />
                The iOS App
              </Link>
            </Button>
          </div>
        </div>
      </section>

      {/* Quickstart */}
      <section className="container mx-auto max-w-7xl px-4 py-24">
        <div className="max-w-3xl mx-auto text-center mb-10">
          <h2 className="text-3xl font-bold tracking-tight mb-4">One command to bring it up</h2>
          <p className="text-lg text-muted-foreground">
            You need a Linux or macOS box with Docker and its Compose plugin. The bootstrap script
            generates every secret, starts the stack, waits for ingest to answer, and prints a
            pairing block: the URL the phone should use, the bearer token, the user ID, and a QR
            code encoding all three.
          </p>
        </div>

        <div className="mx-auto max-w-2xl overflow-x-auto rounded-lg border bg-muted/30 p-5">
          <pre className="text-sm font-mono leading-relaxed text-muted-foreground">
            <code>{`git clone https://github.com/PulsHealth/pulshealth.git
cd pulshealth
scripts/bootstrap.sh --time-zone Europe/Berlin`}</code>
          </pre>
        </div>

        <p className="mx-auto max-w-2xl text-center text-sm text-muted-foreground mt-4">
          Pass the time zone your phone lives in — every daily view buckets by that calendar.
          Re-running the script is safe; it never regenerates secrets.
        </p>
      </section>

      {/* Services Section */}
      <section className="bg-muted/30 border-y">
        <div className="container mx-auto max-w-7xl px-4 py-24">
          <div className="text-center mb-16">
            <h2 className="text-3xl font-bold tracking-tight mb-4">What comes up</h2>
            <p className="text-lg text-muted-foreground max-w-2xl mx-auto">
              Six services, all in the same repository as the app, all yours to inspect and change.
            </p>
          </div>

          <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
            {services.map((service) => (
              <Card key={service.title} className="h-full">
                <CardHeader>
                  <div className="p-3 rounded-xl bg-brand-muted text-brand w-fit mb-4">
                    <service.icon className="h-6 w-6" />
                  </div>
                  <CardTitle>{service.title}</CardTitle>
                  <CardDescription className="text-base">
                    {service.description}
                  </CardDescription>
                </CardHeader>
              </Card>
            ))}
          </div>
        </div>
      </section>

      {/* Exposure Section */}
      <section className="container mx-auto max-w-7xl px-4 py-24">
        <div className="text-center mb-16">
          <h2 className="text-3xl font-bold tracking-tight mb-4">How the phone reaches it</h2>
          <p className="text-lg text-muted-foreground max-w-2xl mx-auto">
            The one decision the script leaves to you. Everything except ingest binds to loopback by
            default — the product API, the MCP server, Grafana, the viewer and Postgres included.
          </p>
        </div>

        <div className="grid grid-cols-1 md:grid-cols-3 gap-8 max-w-5xl mx-auto">
          <div className="text-center">
            <div className="mx-auto mb-4 p-4 rounded-2xl bg-background border w-fit">
              <Plug className="h-8 w-8 text-brand" />
            </div>
            <h3 className="text-xl font-semibold mb-2">Same Wi-Fi</h3>
            <p className="text-muted-foreground">
              Bind ingest to the LAN and the pairing block carries a local address; the app accepts
              plain HTTP for local-network hosts. That is plaintext with the token as the only
              protection — fine on a network you control, nowhere else.
            </p>
          </div>
          <div className="text-center">
            <div className="mx-auto mb-4 p-4 rounded-2xl bg-background border w-fit">
              <Globe className="h-8 w-8 text-brand" />
            </div>
            <h3 className="text-xl font-semibold mb-2">From Anywhere</h3>
            <p className="text-muted-foreground">
              Put a TLS-terminating proxy or a VPN such as Tailscale in front of the ingest port and
              hand the script its URL. Ingest stays on loopback and the QR code carries the HTTPS
              address.
            </p>
          </div>
          <div className="text-center">
            <div className="mx-auto mb-4 p-4 rounded-2xl bg-background border w-fit">
              <HardDriveDownload className="h-8 w-8 text-brand" />
            </div>
            <h3 className="text-xl font-semibold mb-2">Backups Are Yours</h3>
            <p className="text-muted-foreground">
              A backup service ships with the stack, but it is an opt-in Compose profile and off
              until you turn it on. Until then the Postgres volume is the only copy of your data.
            </p>
          </div>
        </div>
      </section>

      {/* Package + Protocol Section */}
      <section className="bg-muted/30 border-y">
        <div className="container mx-auto max-w-7xl px-4 py-24">
          <div className="grid md:grid-cols-2 gap-8 max-w-5xl mx-auto">
            <Card className="h-full">
              <CardHeader>
                <div className="p-3 rounded-xl bg-brand-muted text-brand w-fit mb-4">
                  <Package className="h-6 w-6" />
                </div>
                <CardTitle>PulsHealthSync, the Swift package</CardTitle>
                <CardDescription className="text-base">
                  The sync engine underneath the app, and a package in its own right: iOS 17+,
                  Swift 6 strict concurrency, zero third-party dependencies. Anchored-query sync,
                  on-device aggregates, activity rings, background scheduling, the HTTP transport
                  and the NDJSON encoding — embeddable in another app if you want the pipeline
                  without the UI.
                </CardDescription>
              </CardHeader>
              <CardContent>
                <Button asChild variant="outline">
                  <a href={`${GITHUB}/tree/main/PulsHealthSync`} target="_blank" rel="noopener noreferrer">
                    Read the Package Docs
                    <ArrowRight className="ml-2 h-4 w-4" />
                  </a>
                </Button>
              </CardContent>
            </Card>

            <Card className="h-full">
              <CardHeader>
                <div className="p-3 rounded-xl bg-brand-muted text-brand w-fit mb-4">
                  <Terminal className="h-6 w-6" />
                </div>
                <CardTitle>Or bring your own backend</CardTitle>
                <CardDescription className="text-base">
                  This stack is one receiver, not the only one. A receiver has to accept the batch,
                  deduplicate samples by UUID, upsert aggregate buckets and activity summaries, and
                  return 2xx. All of that is specified in the Puls Sync Protocol v1, with a JSON
                  Schema per line type, a fixture corpus, a batch checker, and a complete receiver
                  in one standard-library Python file writing to SQLite.
                </CardDescription>
              </CardHeader>
              <CardContent>
                <Button asChild variant="outline">
                  <Link href="/docs/protocol">
                    Read the Specification
                    <ArrowRight className="ml-2 h-4 w-4" />
                  </Link>
                </Button>
              </CardContent>
            </Card>
          </div>
        </div>
      </section>

      {/* Security note + CTA */}
      <section className="container mx-auto max-w-7xl px-4 py-24 text-center">
        <div className="mx-auto mb-6 p-4 rounded-2xl bg-brand-muted text-brand w-fit">
          <ShieldCheck className="h-8 w-8" />
        </div>
        <h2 className="text-3xl font-bold tracking-tight mb-4">
          Self-hosting means self-securing
        </h2>
        <p className="text-lg text-muted-foreground max-w-2xl mx-auto mb-8">
          The database holds identifiable health data, and ingest currently accepts a single static
          bearer token, so whoever holds it can upload and delete for any user on that server. TLS,
          exposure and retention are yours to arrange. The project documents its own limitations
          rather than glossing over them.
        </p>
        <div className="flex flex-col sm:flex-row gap-4 justify-center">
          <Button asChild size="lg" className="bg-brand hover:bg-brand-dark text-brand-foreground">
            <a href={`${GITHUB}/blob/main/SECURITY.md`} target="_blank" rel="noopener noreferrer">
              Security Notes
              <ArrowRight className="ml-2 h-4 w-4" />
            </a>
          </Button>
          <Button asChild size="lg" variant="outline">
            <Link href="/privacy">
              Privacy Policy
            </Link>
          </Button>
        </div>
      </section>
    </main>
  );
}
