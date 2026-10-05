import { redirect } from "next/navigation";

export const dynamic = "force-dynamic";

export default async function SleepPage({
  searchParams,
}: {
  searchParams: Promise<{ range?: string }>;
}) {
  const params = await searchParams;
  const query = params.range ? `?range=${encodeURIComponent(params.range)}` : "";
  redirect(`/category/sleep${query}`);
}
