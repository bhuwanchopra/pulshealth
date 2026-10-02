import Link from "next/link";
import { Mail, MessageSquare, BarChart3, Bot, Database, FileCode2, Server } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { PageHero } from "@/components/page-hero";
import dynamic from "next/dynamic";

const QuoteRequestDialog = dynamic(
  () => import("@/components/quote-request-dialog").then((mod) => mod.QuoteRequestDialog),
);

const GITHUB = "https://github.com/PulsHealth/pulshealth";

export const metadata = {
  title: "Consulting - Set Up, Self-Host and Build with PulsHealth",
  description: "Help with getting the self-hosted stack running, connecting health data to AI tooling over MCP, implementing the Puls Sync Protocol against your own backend, and building on the data.",
  alternates: {
    canonical: '/consulting/',
  },
};

const services = [
  {
    title: "Get the Stack Running, and Keep It Running",
    description: "Standing up the reference backend: Docker Compose, PostgreSQL 17 with TimescaleDB, the ingest and product APIs, Grafana, the web viewer. Then everything after that: migrations, backups, upgrades, alerting, and working out why a sync stalled.",
    icon: Server,
  },
  {
    title: "Health Data in Your AI Tooling",
    description: "Wiring your own data into Claude, Claude Code, Cursor or a remote connector through the read-only MCP server, or into ChatGPT through the product API's OpenAPI document. Including the parts that decide whether the answers are any good: deduplication, time zones, and which questions the tools can actually answer.",
    icon: Bot,
  },
  {
    title: "Implement the Sync Protocol",
    description: "You already have a backend and want the app to talk to it. The Puls Sync Protocol v1 is specified with JSON Schema, a fixture corpus and a conformance checker, so this is a well-defined job: I can implement the receiver, review one you have written, or work through the idempotency and retry rules with your team.",
    icon: FileCode2,
  },
  {
    title: "Build on the Data",
    description: "Once the samples are in Postgres they are yours to use. Dashboards, analysis notebooks, exports, and integrations with whatever else you run, plus the schema and query patterns that keep iPhone and Watch from double counting.",
    icon: BarChart3,
  },
  {
    title: "Health-Data Engineering",
    description: "The general case, whether or not it involves this project. Ingest pipelines that stay idempotent under retries, time-series schema and compression, HealthKit's sharper edges, and sizing a system for the volumes a few years of wearable data actually produce.",
    icon: Database,
  },
];

const facts = [
  { value: "80", label: "HealthKit types in the protocol catalog" },
  { value: "178", label: "Type references in the knowledge base" },
  { value: "11", label: "Read-only MCP tools over your data" },
  { value: "v1", label: "Sync protocol, specified with JSON Schema" },
];

export default function ConsultingPage() {
  return (
    <main className="flex min-h-screen flex-col">
      <PageHero
        eyebrow="Consulting"
        title={<>Help setting up, self-hosting, and <span className="text-brand">building with PulsHealth</span></>}
        lede="I wrote PulsHealth: the iOS app, the sync library, the self-hosted stack and the protocol. If you want it set up for you, adapted to a database you already have, or built on, I do that work."
      >
        <QuoteRequestDialog>
          <Button size="lg">
            <Mail className="mr-2 h-4 w-4" />
            Get in Touch
          </Button>
        </QuoteRequestDialog>
        <Button asChild size="lg" variant="outline">
          <Link href="/docs">
            Read the Docs First
          </Link>
        </Button>
      </PageHero>

      {/* Honest framing */}
      <section className="container mx-auto max-w-7xl px-4 py-16">
        <Card className="max-w-3xl mx-auto border-brand/30">
          <CardHeader>
            <CardTitle>Everything here is also free</CardTitle>
            <CardDescription className="text-base">
              You may not need to hire anyone.
            </CardDescription>
          </CardHeader>
          <CardContent>
            <ul className="space-y-4 text-muted-foreground">
              <li>
                <strong className="text-foreground">The whole project is Apache-2.0.</strong>{" "}
                The app, the sync library, the self-hosted stack, the protocol specification and the
                dashboards are all in one public repository. There are no paid features.
              </li>
              <li>
                <strong className="text-foreground">The backend is pre-release.</strong>{" "}
                Standing up the stack still expects someone comfortable with Docker. The
                documentation covers it, but not everyone has the time.
              </li>
              <li>
                <strong className="text-foreground">Try the docs first.</strong>{" "}
                The <Link href="/server" className="text-brand hover:underline">quickstart</Link>,
                the <Link href="/docs/protocol" className="text-brand hover:underline">protocol spec</Link>{" "}
                and the <Link href="/docs/database" className="text-brand hover:underline">database guide</Link>{" "}
                are all on this site. If they get you there, you do not need me.
              </li>
            </ul>
          </CardContent>
        </Card>
      </section>

      {/* Services Section */}
      <section className="container mx-auto max-w-7xl px-4 pb-24">
        <div className="text-center mb-16">
          <h2 className="text-3xl font-bold tracking-tight mb-4">What I can help with</h2>
          <p className="text-lg text-muted-foreground max-w-2xl mx-auto">
            Roughly in the order people ask. If your problem is close to one of these but not
            quite the same, ask anyway.
          </p>
        </div>

        <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
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
      </section>

      {/* Facts Section */}
      <section className="bg-muted/30 border-y">
        <div className="container mx-auto max-w-7xl px-4 py-16">
          <div className="text-center mb-12">
            <h2 className="text-2xl font-bold tracking-tight mb-3">What already exists</h2>
            <p className="text-muted-foreground max-w-2xl mx-auto">
              What is in the repository today, so you can judge how much of your problem is
              already solved.
            </p>
          </div>

          <div className="grid grid-cols-2 md:grid-cols-4 gap-8 text-center">
            {facts.map((fact) => (
              <div key={fact.label}>
                <div className="text-4xl font-bold text-brand mb-2">{fact.value}</div>
                <div className="text-muted-foreground text-sm">{fact.label}</div>
              </div>
            ))}
          </div>

          <p className="text-center text-sm text-muted-foreground mt-10 max-w-2xl mx-auto">
            The README estimates a heavy five-year backfill at fifteen to twenty-five million
            samples and the ingest service at 50 to 100 thousand rows per second, which is why the
            phone, not the database, is the bottleneck. Those are planning figures, not benchmark
            results. The app includes a throughput benchmark so you can measure your own device.
          </p>
        </div>
      </section>

      {/* Contact Section */}
      <section className="container mx-auto max-w-7xl px-4 py-24">
        <div className="max-w-2xl mx-auto text-center">
          <MessageSquare className="h-12 w-12 text-brand mx-auto mb-6" />
          <h2 className="text-3xl font-bold tracking-tight mb-4">Get in touch</h2>
          <p className="text-lg text-muted-foreground mb-8">
            Tell me what you have, what you want it to do, and what is in the way. I will say
            whether I can help. If the answer is already in the docs, I will point you to it.
          </p>

          <div className="mb-8">
            <QuoteRequestDialog>
              <Button size="lg">
                <Mail className="mr-2 h-4 w-4" />
                Get in Touch
              </Button>
            </QuoteRequestDialog>
          </div>

          <Card>
            <CardContent className="pt-6">
              <div className="space-y-6">
                <div className="flex items-center gap-4">
                  <div className="p-3 rounded-lg bg-brand-muted text-brand">
                    <Mail className="h-5 w-5" />
                  </div>
                  <div className="text-left">
                    <p className="font-medium">Email</p>
                    <a href="mailto:support@pulshealth.com" className="text-brand hover:underline">
                      support@pulshealth.com
                    </a>
                  </div>
                </div>
              </div>
            </CardContent>
          </Card>

          <p className="text-sm text-muted-foreground mt-8">
            Bug reports and general questions are better as{" "}
            <a href={`${GITHUB}/issues`} target="_blank" rel="noopener noreferrer" className="text-brand hover:underline">
              GitHub issues
            </a>
            , where the answer helps the next person too. See the{" "}
            <Link href="/support" className="text-brand hover:underline">
              support page
            </Link>
            .
          </p>
        </div>
      </section>
    </main>
  );
}
