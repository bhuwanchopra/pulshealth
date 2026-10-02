import type { Metadata, Viewport } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import "./globals.css";
import { ThemeProvider } from "@/components/theme-provider";
import { SearchProvider } from "@/components/search-context";
import { SearchDialogLoader } from "@/components/search-dialog-loader";
import { SiteHeader } from "@/components/site-header";
import { SiteFooter } from "@/components/site-footer";
import { getRepoStats } from "@/lib/github";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

export const metadata: Metadata = {
  metadataBase: new URL('https://pulshealth.com'),
  title: "PulsHealth - Sync Apple Health to a Database You Run",
  description: "Open-source iOS app to explore and export Apple Health and sync it to a database you run, plus an example self-hosted stack, a documented wire protocol, and a read-only MCP server for AI assistants. Apache-2.0.",
  alternates: {
    canonical: '/',
    types: {
      'application/rss+xml': [{ url: '/feed.xml', title: 'PulsHealth blog' }],
    },
  },
  openGraph: {
    siteName: "PulsHealth",
    images: [{ url: '/og-default.png', width: 1200, height: 630, alt: 'PulsHealth: Apple Health, in a database you run.' }],
  },
  twitter: {
    card: 'summary_large_image',
    images: ['/og-default.png'],
  },
};

export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
  themeColor: [
    { media: "(prefers-color-scheme: light)", color: "#ffffff" },
    { media: "(prefers-color-scheme: dark)", color: "#0a0a0a" },
  ],
};

const GITHUB_URL = "https://github.com/PulsHealth/pulshealth";

/** Organization + WebSite, once, on every page. Pages add their own types. */
const siteJsonLd = {
  "@context": "https://schema.org",
  "@graph": [
    {
      "@type": "Organization",
      "@id": "https://pulshealth.com/#org",
      name: "PulsHealth",
      url: "https://pulshealth.com/",
      logo: "https://pulshealth.com/logo.png",
      sameAs: [GITHUB_URL],
    },
    {
      "@type": "WebSite",
      "@id": "https://pulshealth.com/#site",
      url: "https://pulshealth.com/",
      name: "PulsHealth",
      publisher: { "@id": "https://pulshealth.com/#org" },
    },
  ],
};

export default async function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  const { stars } = await getRepoStats();

  return (
    <html lang="en" suppressHydrationWarning>
      <body
        className={`${geistSans.variable} ${geistMono.variable} antialiased min-h-screen flex flex-col bg-background font-sans text-foreground`}
      >
        <script
          type="application/ld+json"
          dangerouslySetInnerHTML={{ __html: JSON.stringify(siteJsonLd) }}
        />
        <ThemeProvider
          attribute="class"
          defaultTheme="system"
          enableSystem
          disableTransitionOnChange
        >
          <SearchProvider>
            <SiteHeader stars={stars} />
            {children}
            <SiteFooter />
            <SearchDialogLoader />
          </SearchProvider>
        </ThemeProvider>
      </body>
    </html>
  );
}
