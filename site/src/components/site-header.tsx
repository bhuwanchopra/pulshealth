"use client"

import * as React from "react"
import Link from "next/link"
import Image from "next/image"
import { usePathname } from "next/navigation"
import { BookOpen, Briefcase, Database, FileText, LogIn, Menu, PenLine, Smartphone, Star } from "lucide-react"
import { GitHubIcon } from "@/components/brand-icons"

import { cn } from "@/lib/utils"
import { GITHUB_URL, formatStars } from "@/lib/github"
import { Button } from "@/components/ui/button"
import {
  Sheet,
  SheetContent,
  SheetHeader,
  SheetTitle,
  SheetTrigger,
} from "@/components/ui/sheet"
import { ModeToggle } from "@/components/mode-toggle"
import { SearchTrigger } from "@/components/search-trigger"

type NavItem = {
  title: string
  href: string
  description: string
  icon: typeof Smartphone
}

/**
 * Six items, all on-site. Docs are the way into the protocol, the AI setup
 * and the server manual; GitHub is the star pill on the right. Consulting is
 * the business behind the project and stays visible; About and Support live
 * in the footer.
 */
const primary: NavItem[] = [
  { title: "App", href: "/ios", description: "The free iOS app", icon: Smartphone },
  { title: "Database", href: "/server", description: "The self-hosted stack", icon: Database },
  { title: "Docs", href: "/docs", description: "Setup, protocol, database, AI", icon: FileText },
  { title: "Knowledge Base", href: "/knowledge-base", description: "What each Apple Health type measures", icon: BookOpen },
  { title: "Blog", href: "/blog", description: "Posts from the project", icon: PenLine },
  { title: "Consulting", href: "/consulting", description: "Setup, hosting and custom work, from the maintainer", icon: Briefcase },
]

/** The hosted web viewer: another origin, so a plain link, not next/link. */
const APP_URL = "https://app.pulshealth.com/"

const secondary: { title: string; href: string }[] = [
  { title: "Support & FAQ", href: "/support" },
  { title: "About", href: "/about" },
  { title: "Privacy", href: "/privacy" },
]

export function SiteHeader({ stars }: { stars: number | null }) {
  const pathname = usePathname()
  const [open, setOpen] = React.useState(false)

  const isActive = (href: string) => pathname === href || pathname.startsWith(`${href}/`)
  const starLabel = formatStars(stars)

  return (
    <header className="sticky top-0 z-50 w-full border-b bg-background/80 backdrop-blur-md supports-[backdrop-filter]:bg-background/60">
      <div className="container mx-auto flex h-14 max-w-7xl items-center gap-2 px-4">
        <Link href="/" className="mr-4 flex items-center space-x-1.5">
          <Image src="/logo.svg" alt="" width={28} height={28} priority />
          <span className="font-semibold">PulsHealth</span>
        </Link>

        <nav className="hidden items-center gap-1 lg:flex" aria-label="Primary">
          {primary.map((item) => (
            <Link
              key={item.href}
              href={item.href}
              className={cn(
                "rounded-md px-3 py-2 text-sm font-medium text-muted-foreground transition-colors hover:bg-accent hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring",
                isActive(item.href) && "bg-accent/60 text-foreground",
              )}
              aria-current={isActive(item.href) ? "page" : undefined}
            >
              {item.title}
            </Link>
          ))}
        </nav>

        <div className="ml-auto flex items-center gap-2">
          <SearchTrigger />
          <Button asChild variant="outline" size="sm" className="hidden gap-1.5 lg:inline-flex">
            <a href={GITHUB_URL} target="_blank" rel="noopener noreferrer" aria-label="PulsHealth on GitHub">
              <GitHubIcon className="h-4 w-4" />
              {starLabel ? (
                <>
                  <Star className="h-3.5 w-3.5 opacity-70" aria-hidden />
                  <span className="font-mono text-xs tabular-nums">{starLabel}</span>
                </>
              ) : (
                <span className="text-xs">GitHub</span>
              )}
            </a>
          </Button>
          <Button asChild variant="ghost" size="sm" className="hidden lg:inline-flex">
            <a href={APP_URL}>Sign in</a>
          </Button>
          <ModeToggle />

          <Sheet open={open} onOpenChange={setOpen}>
            <SheetTrigger asChild>
              <Button variant="ghost" size="icon" className="lg:hidden">
                <Menu className="h-5 w-5" />
                <span className="sr-only">Open menu</span>
              </Button>
            </SheetTrigger>
            <SheetContent side="right" className="w-full overflow-y-auto sm:w-[400px]">
              <SheetHeader>
                <SheetTitle className="text-left">Menu</SheetTitle>
              </SheetHeader>
              <nav className="mt-6 flex flex-col gap-6" aria-label="Mobile">
                <div className="space-y-1">
                  {primary.map((item) => (
                    <Link
                      key={item.href}
                      href={item.href}
                      onClick={() => setOpen(false)}
                      className={cn(
                        "flex items-center gap-4 rounded-lg px-3 py-3 text-sm transition-colors hover:bg-accent focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring",
                        isActive(item.href) && "bg-accent/60",
                      )}
                    >
                      <item.icon className="h-5 w-5 flex-shrink-0 text-muted-foreground" />
                      <div className="min-w-0">
                        <div className="font-medium">{item.title}</div>
                        <div className="truncate text-xs text-muted-foreground">{item.description}</div>
                      </div>
                    </Link>
                  ))}
                </div>

                <div>
                  <p className="mb-2 px-3 text-xs font-medium uppercase tracking-wider text-muted-foreground">More</p>
                  <div className="space-y-1">
                    {secondary.map((item) => (
                      <Link
                        key={item.href}
                        href={item.href}
                        onClick={() => setOpen(false)}
                        className="block rounded-lg px-3 py-2 text-sm transition-colors hover:bg-accent focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
                      >
                        {item.title}
                      </Link>
                    ))}
                  </div>
                </div>

                <div className="mt-auto space-y-2 border-t pt-4">
                  <Button asChild variant="outline" className="h-12 w-full text-base">
                    <a href={GITHUB_URL} target="_blank" rel="noopener noreferrer" onClick={() => setOpen(false)}>
                      <GitHubIcon className="mr-2 h-4 w-4" />
                      {starLabel ? `Star on GitHub · ${starLabel}` : "View on GitHub"}
                    </a>
                  </Button>
                  <Button asChild variant="ghost" className="h-12 w-full text-base">
                    <a href={APP_URL} onClick={() => setOpen(false)}>
                      <LogIn className="mr-2 h-4 w-4" aria-hidden />
                      Sign in
                    </a>
                  </Button>
                </div>
              </nav>
            </SheetContent>
          </Sheet>
        </div>
      </div>
    </header>
  )
}
