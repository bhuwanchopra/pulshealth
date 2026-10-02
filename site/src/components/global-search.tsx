"use client";

import * as React from "react";
import { useRouter } from "next/navigation";
import { HealthIcon } from "@/components/health-icon";
import Fuse from "fuse.js";
import {
  Home,
  Smartphone,
  Users,
  HelpCircle,
  Info,
  BookOpen,
  Search,
  Newspaper,
  Database,
  Shield,
  FileText,
  LucideIcon,
} from "lucide-react";

import {
  CommandDialog,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
} from "@/components/ui/command";
import { SearchItem, SearchItemType } from "@/lib/types";
import { useSearch } from "@/components/search-context";

// Icon mapping for pages
const PAGE_ICONS: Record<string, LucideIcon> = {
  Home,
  Smartphone,
  Users,
  HelpCircle,
  Info,
  BookOpen,
  Search,
  Newspaper,
  Database,
  Shield,
  FileText,
};

// Type badge component
function TypeBadge({ type, category }: { type: SearchItemType; category?: string }) {
  if (type === 'page') {
    return (
      <span className="text-[10px] uppercase tracking-wider text-blue-600 dark:text-blue-400 bg-blue-100 dark:bg-blue-950 px-1.5 rounded-sm">
        Page
      </span>
    );
  }
  if (type === 'blog') {
    return (
      <span className="text-[10px] uppercase tracking-wider text-purple-600 dark:text-purple-400 bg-purple-100 dark:bg-purple-950 px-1.5 rounded-sm">
        Article
      </span>
    );
  }
  // healthkit type - show category
  return (
    <span className="text-[10px] uppercase tracking-wider text-muted-foreground bg-muted px-1.5 rounded-sm">
      {category || 'Health'}
    </span>
  );
}

interface GlobalSearchDialogProps {
  items: SearchItem[];
  /** True while the index is still being fetched; `items` is empty then. */
  loading?: boolean;
}

export default function GlobalSearchDialog({ items, loading = false }: GlobalSearchDialogProps) {
  const [search, setSearch] = React.useState("");
  const router = useRouter();
  const { open, setOpen } = useSearch();

  // Initialize Fuse.js for unified searching
  const fuse = React.useMemo(() => new Fuse(items, {
    keys: [
      { name: 'title', weight: 1.0 },
      { name: 'description', weight: 0.4 },
      { name: 'category', weight: 0.3 },
      { name: 'tags', weight: 0.2 },
    ],
    threshold: 0.35,
    distance: 100,
    ignoreLocation: true,
  }), [items]);

  // Group search results by type
  const groupedResults = React.useMemo(() => {
    if (!search) return null;

    const results = fuse.search(search).map(result => result.item);

    const pages = results.filter(r => r.type === 'page').slice(0, 5);
    const blog = results.filter(r => r.type === 'blog').slice(0, 5);
    const healthkit = results.filter(r => r.type === 'healthkit').slice(0, 10);

    return { pages, blog, healthkit };
  }, [fuse, search]);

  const runCommand = React.useCallback((command: () => void) => {
    setOpen(false);
    command();
  }, [setOpen]);

  // Get items by type for default view
  const pages = React.useMemo(() =>
    items.filter(i => i.type === 'page').slice(0, 6),
  [items]);

  const blogPosts = React.useMemo(() =>
    items.filter(i => i.type === 'blog').slice(0, 4),
  [items]);

  const healthkitByCategory = React.useMemo(() => {
    const healthkitItems = items.filter(i => i.type === 'healthkit');
    return healthkitItems.reduce((acc, item) => {
      const cat = item.category || "Other";
      if (!acc[cat]) acc[cat] = [];
      acc[cat].push(item);
      return acc;
    }, {} as Record<string, SearchItem[]>);
  }, [items]);

  const sortedCategories = React.useMemo(() =>
    Object.keys(healthkitByCategory).sort(),
  [healthkitByCategory]);

  // Render a search item
  const renderItem = (item: SearchItem) => {
    const PageIcon = item.icon ? PAGE_ICONS[item.icon] : null;

    return (
      <CommandItem
        key={item.id}
        value={item.id}
        onSelect={() => {
          runCommand(() => router.push(item.href));
        }}
      >
        <div
          className="mr-2 flex h-6 w-6 items-center justify-center rounded-md bg-zinc-100 dark:bg-zinc-800 text-zinc-500 dark:text-zinc-400"
          style={{
            backgroundColor: item.color ? `${item.color}20` : undefined,
            color: item.color || undefined
          }}
        >
          {item.type === 'healthkit' ? (
            <HealthIcon iconName={item.icon} category={item.category} className="h-3.5 w-3.5" />
          ) : PageIcon ? (
            <PageIcon className="h-3.5 w-3.5" />
          ) : (
            <FileText className="h-3.5 w-3.5" />
          )}
        </div>
        <div className="flex flex-col min-w-0 flex-1">
          <div className="flex items-center gap-2">
            <span className="font-medium">{item.title}</span>
            <TypeBadge type={item.type} category={item.category} />
          </div>
          <span className="text-xs text-muted-foreground truncate">
            {item.description}
          </span>
        </div>
      </CommandItem>
    );
  };

  return (
    <CommandDialog
      open={open}
      onOpenChange={(isOpen) => {
        setOpen(isOpen);
        if (!isOpen) setSearch("");
      }}
      commandProps={{
        shouldFilter: false
      }}
      className="top-[15%] translate-y-0 sm:max-w-2xl"
    >
      <CommandInput
        value={search}
        onValueChange={setSearch}
        placeholder="Search pages, articles, and health data..."
      />
      <CommandList className="max-h-[60vh] custom-scrollbar">
        {loading ? (
          <div className="py-6 text-center text-sm text-muted-foreground">Loading…</div>
        ) : (
          <CommandEmpty>No results found.</CommandEmpty>
        )}

        {loading ? null : search && groupedResults ? (
          <>
            {groupedResults.pages.length > 0 && (
              <CommandGroup heading="Pages">
                {groupedResults.pages.map(renderItem)}
              </CommandGroup>
            )}
            {groupedResults.blog.length > 0 && (
              <CommandGroup heading="Articles">
                {groupedResults.blog.map(renderItem)}
              </CommandGroup>
            )}
            {groupedResults.healthkit.length > 0 && (
              <CommandGroup heading="Health Data Types">
                {groupedResults.healthkit.map(renderItem)}
              </CommandGroup>
            )}
          </>
        ) : (
          <>
            <CommandGroup heading="Quick Links">
              {pages.map(renderItem)}
            </CommandGroup>

            {blogPosts.length > 0 && (
              <CommandGroup heading="Recent Articles">
                {blogPosts.map(renderItem)}
              </CommandGroup>
            )}

            {sortedCategories.map((category) => (
              <CommandGroup key={category} heading={category}>
                {healthkitByCategory[category].map(renderItem)}
              </CommandGroup>
            ))}
          </>
        )}
      </CommandList>
    </CommandDialog>
  );
}
