# Hermes and the Jevie OpenBot fork

## Install both

Install Git, Python 3.11+, and [uv](https://docs.astral.sh/uv/). Bun or Node/npm is needed for OpenBot. Run:

```bash
python setup_integrations.py --install-hermes --install-openbot
```

Hermes is downloaded at the pinned official revision. OpenBot's **entire pinned MIT source (2,073 files)** is already included as `vendor/openbot-source.tar.gz`, with its license, commit and SHA-256 manifest. The installer verifies the archive, extracts it to `.integrations/openbot-local`, applies the readable `openbot_local/patch.py` overlay, installs the frozen dependencies and writes the six Jevie tenant files. No CopilotKit account is required. Re-running the installer restores this fork's source; put intentional fork changes in the overlay before re-running it.

Bun 1.4.3 is installed through npm if needed. Hermes uses `uv sync --python 3.14`. Installed dependencies, generated private configuration and runtime state are ignored by Git.

## Hermes: evidence-based evolution

`start_jevie.py` automatically discovers the pinned Hermes checkout and Python environment. For a custom installation, set absolute `HERMES_SOURCE` and `HERMES_PYTHON` paths in `.env`. On Windows, the Python executable is `.venv\Scripts\python.exe`; on Linux/macOS it is `.venv/bin/python`.

Add `OPENROUTER_API_KEY` locally and select the **evolver** model in Connections. Research invokes Hermes after evaluating an experiment. `/evolve NVDA` reflects on the previous experiment and then runs fresh research using accumulated lessons. Daily evolution is opt-in in panel 5 and runs only while workers are running.

The evolver defaults to `nvidia/nemotron-3.5-super-vl:free` through OpenRouter. It shares a model ID with the strategy decider but uses its own reflection context and per-stock lessons. See the [final lineup](README.md#final-openrouter-lineup) for all four debate providers and the paid Jev judgment model. Free-route failures are surfaced; no paid replacement is selected automatically.

The bridge calls the actual `run_agent.AIAgent` with `provider='openrouter'` and `https://openrouter.ai/api/v1`. Tools, background review, unrelated context files and fallback models are disabled. Broker credentials are not passed in its environment. A separate per-stock home stores generated research lessons and a reusable skill. Reflection does not grant tools, alter risk rules or train model weights. Errors are shown rather than replaced with pretend reflection. Offline demo never calls Hermes.

Authenticated inference remains unverified until you supply your OpenRouter key.

## OpenBot without CopilotKit Intelligence

This fork keeps OpenBot's actual application and uses CopilotKit's MIT, open-source **SSE runtime**. `openbot_local/local-runtime.ts` supplies PostgreSQL thread storage, durable event replay, leases and a controller lock. It does not construct a hosted Intelligence client or use its licensed services. No fake project key or license is provided.

**Supabase is hosted PostgreSQL**: it stores the application's conversations, configuration and run coordination. The connected Jevie project has been initialized with 92 OpenBot tables, one durable-thread table and one migration-journal table. All are in private schemas, all have RLS enabled, and neither `anon` nor `authenticated` can access them. There are intentionally no Data API policies: only the trusted backend database owner connects. Supabase's informational [RLS-with-no-policy notice](https://supabase.com/docs/guides/database/database-linter?lint=0008_rls_enabled_no_policy) reflects this deny-by-default design.

In Supabase, open **Connect → Session pooler**, copy the PostgreSQL URI and enter your database password locally. Use port **5432**, not the transaction pooler on 6543: OpenBot needs session locks and notifications. The project URL and publishable key cannot replace this connection string. Do not put the database password or OpenRouter key in GitHub or browser code.

Set Jevie's local `.env`:

```dotenv
OPENROUTER_API_KEY=your-openrouter-key
DATABASE_URL=postgresql://postgres.YOUR_PROJECT_REF:URL_ENCODED_PASSWORD@YOUR_SESSION_POOLER_HOST:5432/postgres?sslmode=verify-full
```

Use the actual host shown by Supabase, and URL-encode password punctuation. Keep certificate verification enabled. The launcher adds the private database search path. For a database you host locally, a standard PostgreSQL 17 connection string works; pgvector is unnecessary.

```bash
python setup_integrations.py --install-openbot
python run_openbot.py --check
python run_openbot.py
```

`--check` checks configuration only; launching actually connects and verifies migrations. A fresh database uses the additive snapshot in `supabase/migrations/`; it refuses existing application schemas rather than overwriting them. Existing initialized schemas are checked against the pinned migration journal.

The launcher generates private encryption and endpoint tokens, creates the app configuration and starts OpenBot at **http://127.0.0.1:3010**, with its API on 3001. Start or restart Jevie in a second terminal using `python start_jevie.py` so it picks up the generated endpoint token. Jevie remains at **http://127.0.0.1:8765**.

For an offline check with your database, use `python run_openbot.py --demo` and `python start_jevie.py --demo`. OpenBot's offline mode blocks external HTTP requests. For a disposable database and automated checks, see below.

The interface defaults to `nvidia/nemotron-3.5-super-vl:free`. Override it with `--model provider/model-id` when launching. The four research providers and Jev keep the lineup in the README. All model calls use OpenRouter; the server receives no Alpaca or direct-provider credentials. The Jevie remote agent is the configured coworker. The server blocks hosted CopilotKit endpoints and direct major-model provider endpoints, and disables telemetry.

This fork is **single-operator and loopback-only**. One controller may use a database at a time; it manages the 2–5 independent stock workers. Losing its database controller lock stops OpenBot. History has an 8 MiB per-thread limit; the recent 2,000 threads are loaded on startup. Events are saved before delivery and finished runs are acknowledged only after their final snapshot is committed. Thread inspection and replay are supported; hosted thread-metadata mutations, managed channels, enterprise Learning and the Intelligence Inspector are not implemented. Hermes supplies Jevie's evolution; OpenBot's native PostgreSQL memory storage remains available. Jevie's trading ledger and per-stock Hermes lessons remain in its existing local stores.

Both API and UI bind to loopback, with an origin/host check on the API. The Bun listener transform is pinned and refuses an unexpected source marker. This setup is not a public multi-user deployment. Do not enable unrelated voice, external agents or plugin providers when keeping an OpenRouter-only installation.

### Connection contract

OpenBot's supported `remote-ag-ui` architecture calls **`http://127.0.0.1:8765/api/ag-ui`**. Its configured `MANAGED_AGENT_TOKEN` equals Jevie's `JEVIE_AGENT_TOKEN` and is sent in `x-openbot-agent-token`. Other clients may send the same server-side token with Bearer authentication. No broker or OpenRouter key is sent to the browser.

The endpoint receives `threadId`, `runId`, `messages` and optional `state.symbol`. It accepts tickers, commands and ordinary discussion messages, streaming RUN_STARTED, TEXT_MESSAGE_START/CONTENT/END and RUN_FINISHED or RUN_ERROR. These are public proposals and critiques, not private model reasoning. Research persists if a stream disconnects; inspect the dashboard for its final job state.

OpenBot uses the same Python research/execution engine as the five-panel UI. This is an actual upstream interface plus a remote strategy coworker, not a claim that upstream OpenBot itself supplies a native trading backtester. Docker/computer agents are unnecessary for this remote coworker; Docker is one optional way to run its required database.

## Source pins and verification limits

| Project | Pinned revision |
|---|---|
| [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) | `92663ae8054ae81f207f46d83512d3f879dc698d` |
| [CopilotKit/OpenBot](https://github.com/CopilotKit/OpenBot) | `636c6fe14c3bba2f3e9b845101f8723e974064b7` |
| Existing Jevie/test1 reference | `0ca471867cf9db6ce08f77a81a01156ffc160f89` |

Verified 2026-10-22:

- Real OpenBot API and UI start with no Intelligence or model key, with telemetry disabled and runtime mode `sse`.
- The real Jevie AG-UI endpoint streams a command response through OpenBot; messages and events persist across full API/database restart.
- Ownership, overlapping leases, stale writes, interrupted-run recovery, replay, the model-network boundary and database-write failures are checked. Cross-origin API requests are refused.
- Supabase contains the additive schema; all 94 tables have RLS. Security advisor reports only the expected informational no-policy notices for private backend-only tables.
- The local test engine is PGlite, which does not emulate independent PostgreSQL sessions fully. The production controller-lock behavior across competing processes still needs a real database integration test.

Reproduce from the repository root after installing OpenBot:

```bash
python -m unittest test_jevie test_upgrades -v
npm ci --prefix openbot_local
node openbot_local/smoke.mjs
```

`openbot_local/export-schema.mjs` rebuilds the additive migration from the pinned upstream chain in an empty disposable database. Never regenerate or reapply a fresh-install migration over an existing installation; create a new reviewed migration for upgrades.

The Supabase plugin could install and verify SQL, but this build workspace could not resolve the direct database host and has no database password. Consequently, the running application was tested against local PostgreSQL protocol tests, **not an authenticated Supabase socket session**. Enter the Session pooler URI locally to complete that connection. OpenRouter/Hermes inference, Alpaca execution and actual broker-fee downloads still require your credentials; no broker orders were placed during this update.

API references: [OpenRouter](https://openrouter.ai/docs/api_reference/overview), [Jev Decisions](https://openrouter.ai/blog/insights/what-is-jev/), [Alpaca orders](https://docs.alpaca.markets/us/docs/working-with-orders), [Alpaca account activities](https://docs.alpaca.markets/us/docs/account-activities).
