"use client";

import { Search } from "lucide-react";
import { useSearch } from "@/components/search-context";

export function KnowledgeBaseSearch() {
  const { setOpen } = useSearch();

  return (
    <button
      onClick={() => setOpen(true)}
      className="w-full flex items-center gap-3 px-4 py-3 rounded-xl border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 text-zinc-500 hover:border-zinc-300 dark:hover:border-zinc-700 hover:shadow-sm transition-all cursor-text"
    >
      <Search className="h-5 w-5 text-zinc-400" />
      <span className="flex-1 text-left">Search 178 health data types...</span>
      <kbd className="hidden sm:inline-flex h-6 items-center gap-1 rounded border border-zinc-200 dark:border-zinc-700 bg-zinc-100 dark:bg-zinc-800 px-2 font-mono text-xs text-zinc-500">
        <span>⌘</span>K
      </kbd>
    </button>
  );
}
