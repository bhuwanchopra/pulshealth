import Link from "next/link";
import { BookOpen, Bug, FileText, Mail, ShieldAlert } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { PageHero } from "@/components/page-hero";
import { faq } from "@/lib/faq";

const GITHUB = "https://github.com/PulsHealth/pulshealth";

export const metadata = {
  title: "Support - Getting Help with PulsHealth",
  description:
    "Where to get help with PulsHealth: the FAQ for the questions that come up most, the documentation, the issue tracker, private vulnerability reporting, and email.",
  alternates: {
    canonical: "/support/",
  },
};

const supportOptions = [
  {
    title: "Documentation",
    description:
      "Setting up the self-hosted stack, the sync protocol, the database guide, exports, and the AI assistant recipes.",
    icon: FileText,
    href: "/docs",
    cta: "Read the Docs",
  },
  {
    title: "Report an Issue",
    description:
      "Bugs, feature requests, and questions from people implementing their own receiver. Issue templates cover each of those.",
    icon: Bug,
    href: `${GITHUB}/issues`,
    cta: "Open an Issue",
    external: true,
  },
  {
    title: "Security Problems",
    description:
      "Anything that looks like a vulnerability goes through GitHub's private reporting, never a public issue. The security policy says what to expect.",
    icon: ShieldAlert,
    href: `${GITHUB}/security/advisories/new`,
    cta: "Report Privately",
    external: true,
  },
  {
    title: "Email",
    description:
      "For anything you would rather not discuss in public. Answers that would help the next person too are better as an issue.",
    icon: Mail,
    href: "mailto:support@pulshealth.com",
    cta: "support@pulshealth.com",
    external: true,
  },
];


export default function SupportPage() {
  return (
    <main className="flex flex-1 flex-col">
      <PageHero
        eyebrow="Support"
        size="compact"
        title="Getting help"
        lede="Most support happens in the open on GitHub, where the answers help the next person too. Start with the FAQ. Most sync questions turn out to be iOS behaviour rather than bugs."
      />

      <section className="container mx-auto max-w-4xl px-4 py-16">
        <h2 className="text-2xl font-bold tracking-tight mb-2">Frequently asked</h2>
        <p className="text-muted-foreground mb-8">
          The same answers as the README.
        </p>
        <dl className="divide-y rounded-lg border bg-card">
          {faq.map((item) => (
            <div key={item.q} className="px-5 py-5">
              <dt className="font-semibold text-foreground">{item.q}</dt>
              <dd className="mt-2 text-muted-foreground text-pretty">{item.a}</dd>
            </div>
          ))}
        </dl>
        <p className="mt-6 text-sm text-muted-foreground">
          Still stuck? The{" "}
          <Link href="/docs" className="text-brand underline-offset-4 hover:underline">
            documentation
          </Link>{" "}
          covers the self-hosted stack, the protocol and the database in depth, and the{" "}
          <Link href="/knowledge-base" className="text-brand underline-offset-4 hover:underline">
            knowledge base
          </Link>{" "}
          explains what each Apple Health type actually measures.
        </p>
      </section>

      <section className="border-t bg-muted/30">
        <div className="container mx-auto max-w-4xl px-4 py-16">
          <h2 className="text-2xl font-bold tracking-tight mb-8">Where to go next</h2>
          <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
            {supportOptions.map((option) => (
              <Card key={option.title} className="h-full">
                <CardHeader>
                  <div className="p-3 rounded-xl bg-brand-muted text-brand w-fit mb-3">
                    <option.icon className="h-6 w-6" />
                  </div>
                  <CardTitle>{option.title}</CardTitle>
                  <CardDescription className="text-base">{option.description}</CardDescription>
                </CardHeader>
                <CardContent>
                  <Button asChild variant="outline">
                    {option.external ? (
                      <a href={option.href} target={option.href.startsWith("mailto:") ? undefined : "_blank"} rel="noopener noreferrer">
                        {option.cta}
                      </a>
                    ) : (
                      <Link href={option.href}>{option.cta}</Link>
                    )}
                  </Button>
                </CardContent>
              </Card>
            ))}
          </div>
          <p className="mt-8 text-sm text-muted-foreground flex items-center gap-2">
            <BookOpen className="h-4 w-4" />
            Want it set up for you, or built on? See{" "}
            <Link href="/consulting" className="text-brand underline-offset-4 hover:underline">
              consulting
            </Link>
            .
          </p>
        </div>
      </section>
    </main>
  );
}
