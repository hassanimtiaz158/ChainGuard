import Link from "next/link";

const TECH_STACK = [
  "Solidity",
  "EVM",
  "Foundry",
  "Hardhat",
  "OpenZeppelin",
  "Slither",
  "FastAPI",
  "Next.js",
  "Docker",
];

export default function HomePage() {
  return (
    <main className="mx-auto flex min-h-screen max-w-3xl flex-col items-center justify-center gap-8 px-6 py-16 text-center">
      <div className="space-y-4">
        <h1 className="text-4xl font-bold tracking-tight sm:text-5xl">ChainGuard</h1>
        <p className="text-lg text-muted-foreground">
          Watch a reentrancy attack drain a vault on a <strong>local Anvil chain</strong> — then run the
          same attack against the hardened contract and watch it fail.
        </p>
      </div>

      <div className="flex flex-wrap justify-center gap-3">
        <Link
          href="/lab"
          className="rounded-md bg-primary px-6 py-3 font-medium text-primary-foreground transition-colors hover:bg-primary/90"
        >
          Try the Lab
        </Link>
        <Link
          href="/analyzer"
          className="rounded-md border border-input px-6 py-3 font-medium transition-colors hover:bg-accent"
        >
          Scan a Contract
        </Link>
      </div>

      <ul className="flex flex-wrap justify-center gap-2" aria-label="Tech stack">
        {TECH_STACK.map((tech) => (
          <li
            key={tech}
            className="rounded-full border border-border bg-card px-3 py-1 text-xs text-muted-foreground"
          >
            {tech}
          </li>
        ))}
      </ul>

      <p className="max-w-xl text-xs text-muted-foreground">
        Educational use only. All attacks run against ChainGuard&apos;s own contracts on a local chain
        (chain ID 31337). Uploaded Solidity is compiled and statically analyzed only — never deployed
        or executed.
      </p>
    </main>
  );
}