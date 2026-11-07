import type { Metadata } from "next";
import "./globals.css";

// Variable Inter (no fixed weights), so the theme's in-between Medium (560)
// renders as set.
export const metadata: Metadata = {
  title: "OpenUI",
  description: "Managed OpenUI Cloud Chat with web and image search tools",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en" suppressHydrationWarning>
      <body>{children}</body>
    </html>
  );
}
