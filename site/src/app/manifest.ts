import type { MetadataRoute } from "next";

export const dynamic = "force-static";

export default function manifest(): MetadataRoute.Manifest {
  return {
    name: "PulsHealth",
    short_name: "PulsHealth",
    description: "Apple Health, in a database you run.",
    start_url: "/",
    display: "browser",
    background_color: "#0a0a0a",
    theme_color: "#0092ff",
    icons: [
      { src: "/icon.svg", type: "image/svg+xml", sizes: "any" },
      { src: "/apple-icon.png", type: "image/png", sizes: "180x180" },
    ],
  };
}
