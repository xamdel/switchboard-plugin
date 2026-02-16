#!/usr/bin/env npx tsx

async function main() {
  const command = process.argv[2];
  const flags = process.argv.slice(3);

  if (command === "setup") {
    if (flags.includes("--non-interactive")) {
      const { runSetupNonInteractive } = await import("./setup-non-interactive.js");
      await runSetupNonInteractive();
    } else {
      const { runSetup } = await import("./setup.js");
      await runSetup();
    }
  } else if (command === "start") {
    const { runStart } = await import("./start.js");
    await runStart();
  } else {
    console.error("Sixerr Plugin CLI");
    console.error("");
    console.error("Usage:");
    console.error("  sixerr setup                  — Interactive configuration wizard");
    console.error("  sixerr setup --non-interactive — Headless setup from env vars");
    console.error("  sixerr start                  — Connect to Sixerr server");
    process.exit(1);
  }
}

main().catch((err) => {
  console.error(err.message ?? err);
  process.exit(1);
});
