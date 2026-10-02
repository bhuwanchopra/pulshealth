import Link from "next/link";
import { ArrowUpRight } from "lucide-react";

import { PageHero } from "@/components/page-hero";
import { Card, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { docHref, getDocsByGroup } from "@/lib/docs";

const GITHUB = "https://github.com/PulsHealth/pulshealth";

export const metadata = {
  title: "Documentation - PulsHealth",
  description:
    "The PulsHealth documentation: setting up the self-hosted stack, the Puls Sync Protocol specification, the database guide, exports, and using your health data with AI assistants.",
  alternates: {
    canonical: "/docs/",
  },
};

const groupLedes: Record<string, string> = {
  "Getting started": "Bring the stack up and point the app at it.",
  Reference: "The wire format, the database, the APIs and the pieces around them.",
  Project: "How the project is run: reporting problems, what shipped, what is next.",
};

export default function DocsPage() {
  return (
    <main className="flex min-h-screen flex-col">
      <PageHero
        eyebrow="Documentation"
        size="compact"
        title="The manuals"
        lede="Everything is written next to the code it describes and rendered here from the same files, so the page you read is the file in the repository."
      />
      <section className="container mx-auto max-w-5xl px-4 py-16">
        {getDocsByGroup().map(({ group, docs }) => (
          <div key={group} className="mb-14 last:mb-0">
            <h2 className="text-2xl font-bold tracking-tight">{group}</h2>
            {groupLedes[group] && <p className="mt-1 mb-6 text-muted-foreground">{groupLedes[group]}</p>}
            <div className="grid gap-6 sm:grid-cols-2">
              {docs.map((doc) => (
                <Link key={doc.slug} href={docHref(doc.slug)} className="group">
                  <Card className="h-full transition-colors hover:border-brand/40">
                    <CardHeader>
                      <CardTitle className="transition-colors group-hover:text-brand">{doc.title}</CardTitle>
                      <CardDescription className="text-base">{doc.description}</CardDescription>
                      <p className="pt-1 font-mono text-xs text-muted-foreground">{doc.repoPath}</p>
                    </CardHeader>
                  </Card>
                </Link>
              ))}
            </div>
          </div>
        ))}

        <p className="mt-16 border-t pt-8 text-sm text-muted-foreground">
          Looking for something not listed here? Every other document, the schemas and the code itself are in the
          repository.{" "}
          <a
            href={GITHUB}
            target="_blank"
            rel="noopener noreferrer"
            className="inline-flex items-center gap-0.5 text-brand hover:underline"
          >
            Browse the repository
            <ArrowUpRight className="h-3.5 w-3.5" />
          </a>
        </p>
      </section>
    </main>
  );
}
