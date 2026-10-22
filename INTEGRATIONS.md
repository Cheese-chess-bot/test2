# Official Hermes and OpenBot installations

## Install both

Install Git, Python 3.11+, and [uv](https://docs.astral.sh/uv/). Bun or Node/npm is needed for OpenBot. Run:

```bash
python setup_integrations.py --install-hermes --install-openbot
```

This retrieves pinned official sources, installs Hermes with `uv sync --python 3.14`, installs Bun 1.4.3 through npm if needed, and runs OpenBot's frozen-lockfile dependency install. It writes all six Jevie tenant files. Source/dependencies stay under `.integrations/` and are not uploaded to GitHub. The installer refuses to overwrite locally modified upstream sources.

The completed development checks installed/imported the real Hermes `AIAgent`, installed OpenBot's 1,181 dependencies, loaded its tenant through its real parser, and built its actual frontend. No replacement implementation is represented as a connected upstream runtime.

## Hermes: evidence-based evolution

`start_jevie.py` automatically discovers the pinned Hermes checkout and Python environment. For a custom installation, set absolute `HERMES_SOURCE` and `HERMES_PYTHON` paths in `.env`. On Windows, the Python executable is `.venv\Scripts\python.exe`; on Linux/macOS it is `.venv/bin/python`.

Add `OPENROUTER_API_KEY` locally and select the **evolver** model in Connections. Research invokes Hermes after evaluating an experiment. `/evolve NVDA` reflects on the previous experiment and then runs fresh research using accumulated lessons. Daily evolution is opt-in in panel 5 and runs only while workers are running.

The bridge calls the actual `run_agent.AIAgent` with `provider='openrouter'` and `https://openrouter.ai/api/v1`. Tools, background review, unrelated context files and fallback models are disabled. Broker credentials are not passed in its environment. A separate per-stock home stores generated research lessons and a reusable skill. Reflection does not grant tools, alter risk rules or train model weights. Errors are shown rather than replaced with pretend reflection. Offline demo never calls Hermes.

Authenticated inference remains unverified until you supply your OpenRouter key.

## OpenBot: actual application and remote coworker

The pinned upstream requires **PostgreSQL with pgvector** and a **CopilotKit Intelligence project key**. Managed Intelligence does not require a separate license token. The key is infrastructure for OpenBot's threads/runtime; trading model requests continue through OpenRouter. Its default automatic-learning and proactive sources are disabled in this launcher; Hermes supplies Jevie's evolution.

Use your own PostgreSQL instance, or create a dedicated local database, for example with Docker:

```bash
docker run --name jevie-openbot-db -e POSTGRES_USER=openbot -e POSTGRES_PASSWORD=replace-with-local-password -e POSTGRES_DB=openbot -p 127.0.0.1:5432:5432 -v jevie-openbot-db:/var/lib/postgresql/data -d pgvector/pgvector:pg16
```

Set these locally in Jevie's `.env`:

```dotenv
OPENROUTER_API_KEY=your-openrouter-key
INTELLIGENCE_API_KEY=your-copilotkit-project-key
DATABASE_URL=postgres://openbot:your-local-password@127.0.0.1:5432/openbot
```

URL-encode special characters in the database password. Obtain the project key through [CopilotKit Intelligence](https://intelligence.copilotkit.ai); do not use a fabricated key. Then:

```bash
python run_openbot.py --check
python run_openbot.py
```

The launcher checks prerequisites, generates private encryption/endpoint tokens locally, runs upstream database migrations, generates the actual app configuration, and starts the official API/UI. Restart Jevie after the endpoint token is first generated, then open **http://127.0.0.1:3010** for OpenBot and **http://127.0.0.1:8765** for Jevie.

Both listeners bind to loopback. Since this upstream revision has no API host setting, a Bun loader applies one narrowly scoped `hostname: '127.0.0.1'` insertion to its HTTP listener in memory. It verifies the source marker and refuses if that marker changes; it does not rewrite the pinned checkout. The UI receives Vite's `--host 127.0.0.1`. This single-user setup is for local use, not public hosting.

The launcher supplies only the OpenRouter key to the OpenAI-compatible client, fixes `OPENAI_BASE_URL=https://openrouter.ai/api/v1`, selects an exact OpenRouter model and withholds broker/direct-provider credentials. It registers only the Jevie remote coworker, allows only `127.0.0.1:8765` as a private agent endpoint, and disables automatic Learning/proactive defaults. Do not enable unrelated voice, agent or plugin providers if you require an OpenRouter-only deployment.

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

Retrieved 2026-10-22. Source and dependencies were installed in the build workspace; a GitHub clone runs the installer to reproduce them. **Missing during development:** OpenRouter key, Alpaca keys, CopilotKit Intelligence key and database service. Consequently, no authenticated Hermes reflection, full OpenBot server session, actual fee download or paper/live order submission is claimed as tested.

API references: [OpenRouter](https://openrouter.ai/docs/api_reference/overview), [Jev Decisions](https://openrouter.ai/blog/insights/what-is-jev/), [Alpaca orders](https://docs.alpaca.markets/us/docs/working-with-orders), [Alpaca account activities](https://docs.alpaca.markets/us/docs/account-activities).
