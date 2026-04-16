# CLAUDE.md

## Your job in this repo

`fifth-builder` is an **automated build worker for [leftclaw.services](https://leftclaw.services)** — specifically service type 6 (dApp builds). The whole worker is a single shell script, `run.sh`. When it runs, it polls LeftClaw for an open build job, accepts it on-chain (on Base), scaffolds a fresh Scaffold-ETH 2 project, drives multiple `claude -p` agents through a **build → audit/fix → deploy** pipeline, ships contracts to Base via Alchemy, uploads the static frontend to IPFS via bgipfs, and closes the job on-chain.

**Your role as the interactive agent in this directory** is to help operate, debug, and improve that worker — `run.sh`, its environment, the skill prompts it injects, and the output repos it produces under `builds/`. You are *not* the agent that `run.sh` spawns to build the dApps themselves; those are separate `claude -p` subprocesses invoked from inside the script with their own prompts.

See `README.md` for the full pipeline walkthrough and env-var table.

## The skill files `run.sh` relies on

The subagents that `run.sh` invokes are instructed to fetch and follow these at runtime. When editing worker prompts or diagnosing a failed build, go read the live skill — it's authoritative and updates without touching `run.sh`.

### ethskills.com — Ethereum knowledge for AI agents

- **[ethskills.com/SKILL.md](https://ethskills.com/SKILL.md)** — master index. Corrects stale training-data assumptions (gas is <1 gwei, Foundry not Hardhat, Base is cheapest major L2, etc.) and routes to every sub-skill below. Also has a "what to fetch by task" table.
- **[orchestration/SKILL.md](https://ethskills.com/orchestration/SKILL.md)** — the three-phase SE-2 build system (Phase 1 local fork + UI, Phase 2 live contracts + local UI, Phase 3 production). Contains the *hard rules*: use Scaffold hooks not raw wagmi, `yarn fork` not `yarn chain`, never edit `deployedContracts.ts`, put external contracts in `externalContracts.ts` before the frontend. Also the "NEVER COMMIT SECRETS" section our worker's pre-commit guards are modeled on.
- **[frontend-ux/SKILL.md](https://ethskills.com/frontend-ux/SKILL.md)** — per-button loaders, three-button flow (Switch Network → Approve → Execute), `<Address/>`/`<AddressInput/>` everywhere, USD values next to token amounts.
- **[frontend-playbook/SKILL.md](https://ethskills.com/frontend-playbook/SKILL.md)** — build-to-production pipeline. Key load-bearing gotchas for our worker: `trailingSlash: true` for IPFS, always clean (`rm -rf .next out`) before deploy, Node 25+ localStorage polyfill.
- **[qa/SKILL.md](https://ethskills.com/qa/SKILL.md)** — pre-ship QA checklist for a reviewer agent. Our worker's audit cycle tells the auditor to follow this for the frontend half of the report.
- **[audit/SKILL.md](https://ethskills.com/audit/SKILL.md)** — deep EVM contract audit system. 19 domain-specific checklists under `evm-audit-skills`, routed from a master index at `github.com/austintgriffith/evm-audit-skills`. Our worker's audit cycle tells the auditor to follow this for the contract half of the report.

### Scaffold-ETH 2

- **[docs.scaffoldeth.io/SKILL.md](https://docs.scaffoldeth.io/SKILL.md)** — how an agent scaffolds an SE-2 project with `create-eth@latest` and reads `AGENTS.md`. Small file; "do not summarize, follow step by step."
- **[scaffold-eth/scaffold-eth-2 AGENTS.md](https://github.com/scaffold-eth/scaffold-eth-2/blob/main/AGENTS.md)** — authoritative project-structure / hooks / conventions guide. Lives inside every scaffolded project at the repo root.

### bgipfs (static frontend hosting)

- **[bgipfs.com/SKILL.md](https://www.bgipfs.com/SKILL.md)** — how to upload a built static app and get a permanent IPFS URL. Our STEP 4 uses this via `npx bgipfs@latest upload`. Auth uses `X-API-Key` header (not `Authorization: Bearer`) — that's the one gotcha.

## Rules

- **Never log to `/tmp/`.** All log files go inside this project, under `logs/`. The user wants to be able to `tail -f logs/<thing>.log` from the project folder without hunting around the filesystem. `logs/` is gitignored. Applies to run.sh output, deploy logs, bgipfs upload logs, ad-hoc redirects — everything.
- **Never pick a tool that triggers a permission prompt.** If an auto-allowed tool (Bash, Read, Edit, Write, Grep, Glob) can do the job, use it — even if another tool fits more elegantly. Example: for watching a long-running script's log, use `Bash` with `tail`, not `Monitor`. If a prompt does fire, that's a bug in my tool choice, not a neutral event — own it.
