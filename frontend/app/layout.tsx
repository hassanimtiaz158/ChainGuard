import type { Metadata } from "next";
import type { ReactNode } from "react";

import "./globals.css";

export const metadata: Metadata = {
  title: {
    default: "ChainGuard — Smart Contract Attack Simulator",
    template: "%s · ChainGuard",
  },
  description:
    "Run real attacks against deliberately vulnerable contracts on a local Anvil chain, then re-run them against the hardened version. Educational use only.",
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en" className="dark">
      <body className="min-h-screen bg-background font-sans antialiased">{children}</body>
    </html>
  );
}