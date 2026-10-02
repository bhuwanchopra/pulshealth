import Link from "next/link";
import { ArrowRight, Bot, Code2, Database, FileText, Globe, HardDriveDownload, LayoutDashboard, LineChart, Package, Plug, Server, ShieldCheck, Smartphone, Terminal } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { PageHero } from "@/components/page-hero";

export const metadata = {
  title: "The Self-Hosted PulsHealth Stack",
  description: "The open-source reference backend for PulsHealth: PostgreSQL 17 with TimescaleDB, a Go ingest API, a read-only product API, Grafana, a web viewer and an MCP server, all via Docker Compose on a machine you own.",
  alternates: {
    canonical: '/server/',
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
    description: "Provisioned dashboards for the health data and for ingest health (batches per hour, rows per day, per-type totals, last-batch age), with alert rules already defined.",
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
      <PageHero
        eyebrow={<>Docker Compose &middot; Apache-2.0</>}
        title={<>Your own <span className="text-brand">health database</span></>}
        lede="The open-source database stack the PulsHealth app syncs to: PostgreSQL with TimescaleDB and the services around it. It runs on a home machine, a NAS, or a rented box. There is no hosted option and no managed tier."
      >
        <Button asChild size="lg">
          <Link href="/docs/server">
            <FileText className="mr-2 h-4 w-4" />
            Setup Guide
          </Link>
        </Button>
        <Button asChild variant="outline" size="lg">
          <Link href="/ios">
            <Smartphone className="mr-2 h-4 w-4" />
            The iOS App
          </Link>
        </Button>
      </PageHero>

      {/* Quickstart */}
      <section className="container mx-auto max-w-7xl px-4 py-24">
        <div className="max-w-3xl mx-auto text-center mb-10">
          <h2 className="text-3xl font-bold tracking-tight mb-4">Setup</h2>
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
          Pass the time zone your phone lives in, since every daily view buckets by that
          calendar. Re-running the script is safe; it never regenerates secrets.
        </p>
        <p className="mx-auto max-w-2xl text-center text-sm text-muted-foreground mt-3">
          The script pulls the published images from GHCR. Add <code>--build</code> to compile
          them from the checkout instead, for example to run an unreleased change.
        </p>
      </section>

      {/* Services Section */}
      <section className="bg-muted/30 border-y">
        <div className="container mx-auto max-w-7xl px-4 py-24">
          <div className="text-center mb-16">
            <h2 className="text-3xl font-bold tracking-tight mb-4">What comes up</h2>
            <p className="text-lg text-muted-foreground max-w-2xl mx-auto">
              Six services plus a one-shot migrator, all in the same repository as the app, all
              yours to inspect and change.
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
            Everything binds to loopback by default, including ingest, the product API, the MCP
            server, Grafana, the viewer and Postgres. How the phone reaches ingest is up to you.
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
              protection, so use it only on a network you control.
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
                  The sync engine underneath the app, usable on its own: iOS 17+, Swift 6 strict
                  concurrency, zero third-party dependencies. Anchored-query sync, on-device
                  aggregates, activity rings, background scheduling, the HTTP transport and the
                  NDJSON encoding. Embed it in another app if you want the pipeline without the UI.
                </CardDescription>
              </CardHeader>
              <CardContent>
                <Button asChild variant="outline">
                  <Link href="/docs/swift-package">
                    Read the Package Docs
                    <ArrowRight className="ml-2 h-4 w-4" />
                  </Link>
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
          Security is your job too
        </h2>
        <p className="text-lg text-muted-foreground max-w-2xl mx-auto mb-8">
          The database holds identifiable health data. Each phone can have its own bearer token,
          bound to one user, stored only as a hash and revocable on its own. The shared token a new
          install starts with still works until you switch it off, and anyone who has that one can
          upload and delete for any user in the database. TLS, network exposure and retention are
          yours to set up. The security policy lists the known limitations.
        </p>
        <div className="flex flex-col sm:flex-row gap-4 justify-center">
          <Button asChild size="lg">
            <Link href="/docs/security">
              Security Policy
              <ArrowRight className="ml-2 h-4 w-4" />
            </Link>
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
