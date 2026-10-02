import { getAllTypes } from "@/lib/api";
import Link from "next/link";
import { ArrowRight } from "lucide-react";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { HealthIcon } from "@/components/health-icon";
import { KnowledgeBaseSearch } from "@/components/knowledge-base-search";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "HealthKit Knowledge Base - 178 Apple Health Data Types",
  description: "The missing manual for Apple Health data. Comprehensive reference for all 178 HealthKit data types with clinical ranges, sampling rates, and technical details. Built for AI agents, developers, and researchers.",
  robots: "index, follow, noai, noimageai",
  openGraph: {
    title: "HealthKit Knowledge Base - 178 Apple Health Data Types",
    description: "The missing manual for Apple Health data. Comprehensive reference for all 178 HealthKit data types with clinical ranges, sampling rates, and technical details.",
    images: [{ url: '/og-default.png', width: 1200, height: 600 }],
  },
  alternates: {
    canonical: '/knowledge-base/',
  },
};

export default async function KnowledgeBasePage() {
  const allTypes = await getAllTypes();

  // Extract unique categories and count
  const categories = Array.from(new Set(allTypes.map(t => t.category))).sort();

  const popularTypes = [
    "HKQuantityTypeIdentifierHeartRate",
    "HKQuantityTypeIdentifierBloodGlucose",
    "HKQuantityTypeIdentifierStepCount",
    "HKQuantityTypeIdentifierBloodPressureSystolic"
  ];

  const featured = allTypes.filter(t => popularTypes.includes(t.identifier));

  return (
    <main className="flex min-h-screen flex-col items-center relative">
      {/* Hero Section */}
      <div className="w-full bg-gradient-to-b from-white to-zinc-50 dark:from-zinc-950 dark:to-zinc-900 pt-20 pb-32 border-b">
        <div className="container mx-auto max-w-7xl px-4 flex flex-col items-center text-center space-y-8">
          <Badge variant="outline" className="px-4 py-1 text-sm rounded-full border-zinc-200 dark:border-zinc-800 bg-white/50 dark:bg-zinc-900/50 backdrop-blur-sm">
            HealthKit Knowledge Base
          </Badge>

          <h1 className="text-4xl md:text-6xl font-bold tracking-tight text-zinc-900 dark:text-zinc-50 max-w-3xl">
            The missing manual for <span className="text-brand">Apple Health</span> data — built for AI.
          </h1>

          <p className="text-lg md:text-xl text-zinc-500 max-w-2xl leading-relaxed">
            A comprehensive reference for all 178 HealthKit data types — sampling rates, typical ranges, cross-device comparisons, compaction policies.
            Designed for AI agents, developers, clinicians, and researchers.
          </p>

          <div className="w-full max-w-2xl pt-4">
            <KnowledgeBaseSearch />
          </div>

          <div className="flex flex-wrap justify-center gap-2 pt-2 text-sm text-zinc-500">
            <span>Popular:</span>
            {featured.slice(0, 3).map(f => (
              <Link
                key={f.identifier}
                href={`/knowledge-base/types/${f.identifier}`}
                className="text-zinc-800 dark:text-zinc-300 underline decoration-zinc-300 dark:decoration-zinc-700 hover:decoration-brand underline-offset-4 transition-all"
              >
                {f.human_readable_name}
              </Link>
            ))}
          </div>
        </div>
      </div>

      {/* Categories Grid */}
      <div className="container mx-auto max-w-7xl px-4 py-24">
        <div className="flex justify-between items-end mb-12">
          <div>
            <h2 className="text-2xl font-bold tracking-tight mb-2">Explore Data Types</h2>
            <p className="text-zinc-500">Browse the complete catalog by category.</p>
          </div>
        </div>

        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
          {categories.map((category) => {
            const typesInCategory = allTypes.filter(t => t.category === category);
            const count = typesInCategory.length;

            // Find a representative color/icon for the category from its types
            const representativeType = typesInCategory.find(t => t.icon && t.color) || typesInCategory[0];

            return (
              <Link key={category} href={`/knowledge-base/explore#${category}`} className="group">
                <Card className="h-full transition-all duration-200 hover:border-brand/30 hover:shadow-md">
                  <CardHeader>
                    <div className="flex items-center justify-between">
                      <div
                        className="p-2 rounded-lg group-hover:bg-brand-muted transition-colors bg-zinc-100 dark:bg-zinc-800 text-zinc-500 dark:text-zinc-400"
                        style={{
                          backgroundColor: representativeType?.color ? `${representativeType.color}15` : undefined,
                          color: representativeType?.color || undefined
                        }}
                      >
                        <HealthIcon
                          iconName={representativeType?.icon}
                          category={category}
                          className="h-5 w-5"
                        />
                      </div>
                      <Badge variant="secondary">{count}</Badge>
                    </div>
                    <CardTitle className="mt-4">{category}</CardTitle>
                    <CardDescription className="line-clamp-2">
                        Detailed clinical references for {category.toLowerCase()} metrics.
                    </CardDescription>
                  </CardHeader>
                  <CardContent>
                    <div className="text-sm text-brand flex items-center font-medium opacity-0 group-hover:opacity-100 transition-opacity translate-x-[-10px] group-hover:translate-x-0 duration-200">
                      View all types <ArrowRight className="ml-1 h-4 w-4" />
                    </div>
                  </CardContent>
                </Card>
              </Link>
            );
          })}
        </div>
      </div>
    </main>
  );
}
