import Link from "next/link";
import { Heart, Users, Shield, Target, ArrowRight } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";

export const metadata = {
  alternates: {
    canonical: '/about/',
  },
};

const values = [
  {
    title: "Privacy First",
    description: "Health data is deeply personal. Every layer of PulsHealth — read-only access to Apple Health, one destination you choose, a database you own — is designed so users stay in control of their data.",
    icon: Shield,
  },
  {
    title: "Transparency",
    description: "Open standards, clear documentation, and honest communication. No black boxes or hidden agendas.",
    icon: Target,
  },
  {
    title: "Empowerment",
    description: "We believe everyone — from developers building health AI to individuals tracking their fitness — should have access to health data expertise. We make that knowledge accessible and programmable.",
    icon: Heart,
  },
];

export default function AboutPage() {
  return (
    <main className="flex min-h-screen flex-col">
      {/* Hero Section */}
      <section className="w-full bg-gradient-to-b from-white to-zinc-50 dark:from-zinc-950 dark:to-zinc-900 pt-20 pb-32 border-b">
        <div className="container mx-auto max-w-7xl px-4 flex flex-col items-center text-center space-y-8">
          <Badge variant="outline" className="px-4 py-1 text-sm rounded-full border-zinc-200 dark:border-zinc-800 bg-white/50 dark:bg-zinc-900/50 backdrop-blur-sm">
            About Us
          </Badge>

          <h1 className="text-4xl md:text-6xl font-bold tracking-tight text-zinc-900 dark:text-zinc-50 max-w-4xl">
            Everything AI needs to{" "}
            <span className="text-brand">understand</span> wearable health data
          </h1>

          <p className="text-lg md:text-xl text-zinc-500 max-w-2xl leading-relaxed">
            PulsHealth makes wearable health data reliable, normalized, and privacy-safe for AI — for developers building health products and individuals who want to understand their own data.
          </p>
        </div>
      </section>

      {/* Mission Section */}
      <section className="container mx-auto max-w-7xl px-4 py-24">
        <div className="max-w-3xl mx-auto">
          <h2 className="text-3xl font-bold tracking-tight mb-6">Our Mission</h2>
          <div className="prose prose-zinc dark:prose-invert max-w-none text-lg text-muted-foreground space-y-4">
            <p>
              Consumer wearables generate thousands of health data points daily — heart rate, sleep stages, blood oxygen, activity metrics. Yet this data remains siloed across device ecosystems, fragmented across sampling rates and units, and difficult to interpret without clinical context. AI agents have the potential to unlock actionable insights, but they face significant challenges around privacy, accuracy, and interoperability.
            </p>
            <p>
              We are building the foundation that bridges this gap. Our Knowledge Base distills clinical expertise into structured, AI-ready references. PulsHealthSync handles the real-time collection, normalization, and sync pipeline. A read-only MCP server puts the result in reach of AI assistants without it ever leaving your own server. And our free iOS app gives individuals direct access to understand and export their own health data.
            </p>
            <p>
              Our goal: make wearable health data work — for the builders creating the next generation of health AI, and for the people whose data it is.
            </p>
          </div>
        </div>
      </section>

      {/* Team Section */}
      <section className="bg-muted/30 border-y">
        <div className="container mx-auto max-w-7xl px-4 py-24">
          <div className="text-center mb-16">
            <h2 className="text-3xl font-bold tracking-tight mb-4">Our Team</h2>
            <p className="text-lg text-muted-foreground max-w-2xl mx-auto">
              We bring deep expertise from Apple Health, Google AI, and clinical practice.
            </p>
          </div>

          <div className="max-w-3xl mx-auto">
            <Card>
              <CardContent className="pt-6">
                <div className="flex items-start gap-6">
                  <div className="p-4 rounded-2xl bg-brand-muted text-brand">
                    <Users className="h-8 w-8" />
                  </div>
                  <div>
                    <p className="text-muted-foreground">
                      Our team has spent years building health data systems at scale. We&apos;ve worked on the platforms that collect this data, the AI systems that analyze it, and the clinical workflows that depend on it. We understand both the technical challenges and the human stakes involved.
                    </p>
                  </div>
                </div>
              </CardContent>
            </Card>
          </div>
        </div>
      </section>

      {/* Values Section */}
      <section className="container mx-auto max-w-7xl px-4 py-24">
        <div className="text-center mb-16">
          <h2 className="text-3xl font-bold tracking-tight mb-4">Our Values</h2>
          <p className="text-lg text-muted-foreground max-w-2xl mx-auto">
            The principles that guide everything we build.
          </p>
        </div>

        <div className="grid grid-cols-1 md:grid-cols-3 gap-8">
          {values.map((value) => (
            <div key={value.title} className="text-center">
              <div className="mx-auto mb-4 p-4 rounded-2xl bg-background border w-fit">
                <value.icon className="h-8 w-8 text-brand" />
              </div>
              <h3 className="text-xl font-semibold mb-2">{value.title}</h3>
              <p className="text-muted-foreground">{value.description}</p>
            </div>
          ))}
        </div>
      </section>

      {/* CTA Section */}
      <section className="cta-gradient text-white">
        <div className="container mx-auto max-w-7xl px-4 py-24 text-center">
          <h2 className="text-3xl font-bold tracking-tight mb-4">
            Want to build with us?
          </h2>
          <p className="text-lg opacity-90 max-w-2xl mx-auto mb-8">
            Whether you are building a health coaching agent, running a research study, or just want to understand your own health data — we are here to help.
          </p>
          <div className="flex flex-col sm:flex-row gap-4 justify-center">
            <Button asChild size="lg" variant="secondary">
              <Link href="/consulting">
                Get in Touch
                <ArrowRight className="ml-2 h-4 w-4" />
              </Link>
            </Button>
            <Button asChild size="lg" variant="outline" className="bg-transparent border-brand-foreground/30 hover:bg-brand-foreground/10">
              <Link href="/app">
                Download the App
              </Link>
            </Button>
          </div>
        </div>
      </section>
    </main>
  );
}
