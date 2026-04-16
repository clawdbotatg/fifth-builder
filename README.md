# fifth-builder

Automated build worker for [leftclaw.services](https://leftclaw.services) — service type 6 (dApp builds).

Polls the LeftClaw API for open build jobs, accepts one on-chain, scaffolds a fresh [Scaffold-ETH 2](https://scaffoldeth.io) project, drives Claude through a build → audit → fix → deploy pipeline, ships the contracts to Base via Alchemy and the frontend to IPFS via [bgipfs](https://www.bgipfs.com), then closes the job on-chain.

## What it does

`run.sh` is the whole worker. Given a job, it:

1. **Setup** — accepts the job on-chain, scaffolds `create-eth@latest -s foundry` under `builds/leftclaw-service-job-<id>/`, hardens `.gitignore`, writes a stub `.env` and a `PLAN.md` derived from the client's spec + messages, creates a public GitHub repo under `clawdbotatg`.
2. **Build** — single `claude -p --model claude-opus-4-7` call. Agent reads `PLAN.md`, writes contracts + deploy script + tests + frontend, runs `forge build` / `forge test` / `yarn next:build` until clean, transfers all privileged roles to the client address.
3. **Audit / fix loop** — up to 3 cycles. A separate auditor agent (opus 4.7 on cycle 1, sonnet after) writes `AUDIT_REPORT.md`; a fixer agent (sonnet) works the `## MUST FIX` checklist and annotates `## KNOWN ISSUES` with NatSpec. Loop exits early when zero must-fix items remain.
4. **Deploy** — switches `scaffold.config.ts` to Base, runs the deploy script via `forge script --private-key` (key injected at CLI, never on disk in the build dir), verifies on Basescan, exports the Next.js app, uploads the static build to bgipfs, writes a README, calls `completeJob` on-chain with the live URL.

Resumable: `./run.sh <job-id>` picks up wherever the on-chain `currentStage` says the job is. `./run.sh` with no args polls `/api/job/ready` and takes the next service-type-6 job.

## Skills the build agents are told to follow

The worker prompts reference external skill files that the agents fetch and follow at runtime. These are authoritative — updating them updates worker behavior without touching `run.sh`.

- [ethskills.com/SKILL.md](https://ethskills.com/SKILL.md) — master skill index
  - [orchestration/SKILL.md](https://ethskills.com/orchestration/SKILL.md)
  - [frontend-ux/SKILL.md](https://ethskills.com/frontend-ux/SKILL.md)
  - [frontend-playbook/SKILL.md](https://ethskills.com/frontend-playbook/SKILL.md)
  - [qa/SKILL.md](https://ethskills.com/qa/SKILL.md) — frontend QA framework used by the auditor
  - [audit/SKILL.md](https://ethskills.com/audit/SKILL.md) — contract security audit framework used by the auditor
- [docs.scaffoldeth.io/SKILL.md](https://docs.scaffoldeth.io/SKILL.md) — SE-2 usage for agents
- [scaffold-eth/scaffold-eth-2 AGENTS.md](https://github.com/scaffold-eth/scaffold-eth-2/blob/main/AGENTS.md)
- [bgipfs.com/SKILL.md](https://www.bgipfs.com/SKILL.md) — IPFS upload CLI

## Usage

```sh
./run.sh          # find and work the next open build job
./run.sh 42       # resume job 42 from its current on-chain stage
```

Requires `claude`, `cast`, `forge`, `gh`, `jq`, `yarn`, and `node` on `PATH`.

## Environment (`.env`)

`.env` lives next to `run.sh` and is loaded at startup. It is **never** copied into build directories — the build-dir `.env` gets a stub deployer key (public anvil #0) so `forge build`/`forge test` don't panic on `vm.envUint`, and the real deployer key is injected into `forge script` via `--private-key` at deploy time only.

| Variable | Purpose |
| --- | --- |
| `ETH_PRIVATE_KEY` | Main worker wallet. Accepts jobs, logs work, completes jobs. Never enters project directories. |
| `DEPLOYER_KEYSTORE` | Foundry keystore **name** (not path) for the deployer wallet. Decrypted in memory at startup. |
| `DEPLOYER_PASSWORD` | Password for the deployer keystore. |
| `BASE_RPC_URL` | Full Alchemy RPC URL for Base (worker derives `ALCHEMY_API_KEY` from the trailing path segment). Public RPCs are not acceptable. |
| `BGIPFS_API_KEY` | Upload key for bgipfs.com. |
| `BANKR_API_KEY` | Reserved. |

The deployer wallet needs a small balance on Base (worker assumes ~`0.01 ETH` available for deploys). The main worker wallet needs Base gas for `acceptJob` / `logWork` / `completeJob`.

### Secret hygiene

`run.sh` has been hardened after an incident where an agent leaked the deployer key into `AUDIT_REPORT.md` on a public repo. The current guards:

- Stub deployer key on disk in build dirs — real key only via `forge --private-key`.
- Pre-commit guards in step 1: `.env` must be gitignored, no `PRIVATE_KEY=` / 32-byte hex in staged diff, no `.env` file staged.
- Post-fix-cycle scan of `HEAD` for hex-64 / PEM blocks / `ghp_…` / `sk-…` — hard-aborts the job on match.
- Pre-complete scan over `packages/` for any hex-64 and for the worker's own `ETH_PRIVATE_KEY`.
- Explicit "NEVER reproduce secret values" instructions in the auditor and fixer prompts, with `[REDACTED]` as the required placeholder.

## Layout

```
fifth-builder/
├── run.sh              # the worker
├── .env                # worker secrets (gitignored)
├── .gitignore          # ignores builds/ and .env
└── builds/             # per-job scaffolded repos (gitignored)
    └── leftclaw-service-job-<id>/
```

Per-job outputs also land in `builds/.contract-<id>` (deployed address) and `builds/.url-<id>` (live IPFS URL) as a local cache.

## On-chain

- Chain: Base (8453)
- LeftClaw contract: [`0xb2fb486a9569ad2c97d9c73936b46ef7fdaa413a`](https://basescan.org/address/0xb2fb486a9569ad2c97d9c73936b46ef7fdaa413a)
- Worker calls: `acceptJob(uint256)`, `logWork(uint256,string,string)`, `completeJob(uint256,string)`
- API: `https://leftclaw.services/api/job/{ready,pipeline,<id>,<id>/messages}`
