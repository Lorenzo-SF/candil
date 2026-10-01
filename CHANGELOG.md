# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

The `Candil.EnginePool` API breaks here, on purpose (C13): it was an LRU of
engines with no capacity to enforce, and the 4.0 line is a major. Everything
else in the 4.0 contract freeze is tooling and documentation.

### Added
- `Candil.Build.install/2` with both strategies. `:precompiled` resolves the
  release asset through `Candil.Detector`, downloads it to a `.part` file,
  resumes with `Range: bytes=N-` when one is already there, folds the SHA-256
  in block by block as the bytes go past, renames into place only on success,
  and unpacks the declared binaries into `dir` with the executable bit set.
  `:source` clones the repository, runs `cmake` twice and copies what it finds.
  Options: `:asset_url` to pin the download, `:cmake` for a toolchain that is
  not the one on the `PATH`, `:on_output` to stream compiler output.
  This does not delegate to `Candil.Installer.download_engine/1`, and that is a
  decision rather than an oversight: the installer writes to
  `engine.binary_dir` instead of the plan's own `dir`, reads no `sha256`, has
  no `Range` resume, no `.part` and no rename, and hashes the whole download
  with `File.read/1` — which is B8, and B8 belongs to phase 0. Sharing would
  have meant fixing a phase-0 bug from a phase that is not allowed to touch
  it.
- `Candil.Build.check/1` — `:ok`, or the names of the declared binaries that are
  absent or not executable.
- `Candil.Build.configure_command/1` and `build_command/1` — the exact
  `{executable, argv}` pairs, public so a test can assert the user's
  `cmake_args` are passed verbatim without running a compiler.
- `Candil.Build.jobs/1` — `jobs: 0` resolved to one job per online scheduler,
  which is the `nproc` the user would have typed.
- `Candil.EnginePool.claim_port/2` — a port in `base..max` that is free both as
  far as the registry knows and as far as the operating system is concerned.
  The second half is decided by actually connecting, which is the only way to
  tell a free port from one with a dead `ropero` still holding the socket.
- `Candil.EnginePool.delete/2`, `get/2`, `by_model/1`, `list/0`, `count/0` and
  `ports/0`.
- `proyecto 4.0/candil.toml` — ropero's configuration, translated by hand
  (C15). It loads and validates: 1 engine, 1 provider, 3 consumers, 7 models,
  and all seven register in `Candil.Store`.
- `.tool-versions` pinning Erlang/OTP 28.5.0.7 and Elixir 1.19.5-otp-28, kept
  in sync with the CI env.
- `proyecto 4.0/PLAN-PARALELO.md` — execution plan for the 12 phases: a contract
  freeze, eight lanes with exclusive file ownership, the dependency graph, the
  merge protocol and the token-economy rules.
- `docs/BASELINE-4.0.md` — the measured quality baseline on the
  `4.0-work-start` tag, including why the coverage floor is 50 and not the 70%
  the design document quotes.
- `trebejo`, `alaja` and `botica` as dependencies.
- `benchee` (dev only) for the four hot paths where the design document makes a
  performance claim.
- CI: a weekly `deps-sync` job. All four GitHub deps track `main`, so a
  breaking push to any of them lands here first.
- CI: `mix format --check-formatted` as its own gate, separate from compile.
- CI: `mix docs --warnings-as-errors`, a dialyzer job with its own PLT cache,
  and a coverage floor that can only go up.

### Changed
- **`Candil.EnginePool` is a registry, not a pool.** It was an LRU of engines
  with a `get/0` that returned the least-recently-used one and an `evict/0`
  that nothing called — so it was the record of the last write, wearing a name
  that promised capacity management. Four 20 GB models do not fit, and an LRU
  of four entries does not change that; the LRU was pretending to solve a
  memory-pressure problem nobody has. It is now `%{{alias, port} => instance}`
  with no eviction. `put/1` became `put/5` and is a `call` rather than a
  `cast`, because a cast answers `:ok` whether or not anything was stored, and
  the answer decided which port the next request went to. `get/0` stays for one
  release, deprecated and answering `:empty`; `evict/0` is gone.
- `Candil.Engine.start/2` registers `{model.alias, port}` together with the
  model and the engine, so an instance says what it is serving and not only
  which binary started it.
- `apero` and `arrea` now declare `branch: "main"` explicitly, and all four
  GitHub deps declare `override: true`. Without the branch, a dep silently
  follows whatever the remote HEAD is. Without the override, Mix reads
  `branch: "main"` and no-branch declarations of the same repo as two different
  deps and aborts.
- Credo is un-commented in CI and runs `--format=oneline`. It was disabled
  because strict mode failed on legacy style.
- `.gitignore`: `_build` and `deps` lost their trailing slash, so a symlinked
  build directory is no longer committable.

### Fixed
- `Candil.Config.File.expand/1` never expanded a `draft` path for a model that
  also had a `source`. The two source tables were handled by two function
  clauses with one pattern each, and a model with a `source` never reached the
  `draft` one. The only model in the ropero configuration that has a draft is
  exactly the one that also has a source, so its `--model-draft` path kept a
  literal `~` — which reaches `llama-server` between quotes and becomes a
  directory named `~` (C22). The test that claimed to cover this used a model
  with a draft and no source, which is the one shape that already worked.
- Two CI gates that did not gate anything: `mix deps.audit` does not exist (it
  is `mix hex.audit`), and excoveralls' `minimum_coverage` is only enforced by
  `mix coveralls.html` and `mix coveralls.cobertura`, never by a plain
  `mix test --cover`.
- `mix docs` exits 0 while printing warnings, so the docs job now passes
  `--warnings-as-errors`.

### Fixed — quality gates brought to green (phase -0)
No behaviour change. Every gate below went from failing to passing, so the CI
stops being decoration.

- `mix format` applied across 24 files. `mix format --check-formatted` now
  passes.
- `mix credo --strict` from 37 issues to 0. Two of them needed real refactors
  rather than formatting:
  - `Candil.Agent.loop/7` had a `cond` with a single condition and three
    levels of nesting. The ReAct branch is now `continue_or_finish/8`, so the
    loop reads: cancel? stop-word? otherwise continue.
  - `Candil.Tools.parse_openai_tool_calls/1` was over the complexity limit.
    Per-call parsing moved to `parse_one_call/1`.
- `Candil.Detector.safe_arch/0` used `apply/3` "to keep the compiler happy",
  which is what hid a real dialyzer error: the PLT contained only OTP and
  Candil, so `Trebejo.OS.arch/0` came back as `unknown_function`. The PLT now
  includes `trebejo`, `apero` and `arrea`, the three libraries Candil calls
  into, and the call is direct. All 15 cross-app calls are now type-checked.
- Two stale tests, the cause of all 22 failures. `config_test.exs` cleaned
  `:apero_llm_engines` and friends; the tables are named `:candil_llm_*`.
  `engine_test.exs` expected `~/.apero/llm/bin`; the code returns
  `~/.candil/llm/bin`. The code was right in both cases and the tests were
  wrong — fixing the code to satisfy them would have restored the bug.
- 54 `mix docs` warnings down to 0. The bulk was `Candil.Llm` being
  `@moduledoc false` while `Candil`'s `defdelegate`s inherited its `@doc`s, so
  the entire public facade rendered with unresolvable references. The docs now
  live on `Candil` and `Candil.Llm` stays the hidden implementation.
- `Candil.Backend`'s four callbacks had no `@doc`, and references to them need
  the `c:` prefix rather than a plain function reference.
- Type references in docs now use ExDoc's `t:` prefix, and two references to
  arities that never existed (`Candil.Tool.define/4`, `Candil.Embeddings.embed/3`)
  point at the real ones.

Result: 279 tests, 0 failures, coverage 52.7% to 54.2%, all eight gates green.

### Added — phase -1: contracts (part 1 of N)
- `Candil.Source`. A model file's origin as a value, with three kinds:
  `huggingface` (resolved over HTTPS, so no `hf` CLI is needed — that CLI is
  not installed everywhere and depending on it made the download a separate
  failure mode from the download), `url`, and `local`. Replaces
  `Candil.Model.download_url`.
- `Candil.Build`. Two installation strategies, both declared by the user:
  `:precompiled` downloads a release asset, `:source` clones and compiles with
  **your** `cmake_args`, passed through verbatim. Candil supplies no
  architecture or GPU flag, because it cannot know what `120a` is and a wrong
  guess produces a binary that compiles and runs and is quietly slow.
- `Candil.Error.not_implemented/2` and a new `:not_implemented` reason.

### Changed — phase -1: contracts (part 2): Model and Engine
- `Candil.Engine` gains `binary`, `base_port`, `api_key`, `auth_headers` and
  `install`, and loses `use_precompiled`. The install plan is now the only way
  to say how a binary is obtained, because a boolean and a plan overlapping on
  the same question is how a config ends up meaning two things at once.
- `Candil.Model` gains `port`, `source`, `draft`, `tags`, `enabled`,
  `launcher` and `base_url`; its `type` gains `:external`; and `download_url`
  is gone in favour of `:source`. The port moved here from the engine: one
  engine serves many models, and the same model can run twice at once on a GPU
  slot and a CPU slot, which is what `--cpu` is for.
- `Candil.Engine.auth_headers/1` and `base_url_and_headers/2` are new, and
  they are the fix for the bug that made a ropero server unreachable. The
  local inference path sent a fixed empty header list, so any
  `llama-server` started with `--api-key` answered 401 with no way to inject
  one. Passing `--api-key` is the normal way to run a server that is not on
  loopback, so this was not a ropero quirk.
- `Engine.Server.build_args/2` now emits `--alias` and, when the engine has
  one, `--api-key`. The flag belongs on the command line as well as in the
  headers: a server started with it rejects anything without a matching bearer,
  and Candil is not the only thing that may need to talk to it.
- `Candil.Model.file_path/1` derives the path from `:source` when
  `model_dir`/`filename` are absent, and `Candil.EnginePool` can hand out a
  port from `base_port` for a model whose `port` is `:auto`.

### Fixed
- `Candil.Model.validate/1` no longer raises on a path with `..` in it. It
  used to call `file_path/1`, which raises on traversal, so validating a
  hostile config crashed the validator instead of rejecting it. Traversal and
  "not locatable" are now separate messages, because one of them is a typo and
  the other might not be.
- `Candil.Installer.download_model/1` delegates to `Candil.Source.fetch/2`
  instead of inspecting its result. Until the fetch phase lands, that call
  cannot succeed, and branching on a success that cannot happen turns a stub
  into load-bearing code.

### Changed
- `mix docs` now has four doctests, because the repository ran none at all.
  Every `iex>` example in a moduledoc was previously unverified.

### Fixed
- Two bugs introduced while writing the new modules and caught by their own
  tests, both worth recording because the shape recurs:
  - `require_field/3` had its guards inverted, so it reported a field as
    missing when it was present. `validate/1` would have rejected every
    correctly-configured source.
  - `cmake_command/1` mixed two helpers with different arities and appended a
    boolean to a string list. A build plan would have crashed before invoking
    cmake.

### Changed — phase -1: contracts (part 3): Store and the TOML schema
- `Candil.Config` is now `Candil.Store`. The name said "configuration" but the
  job is the catalogue of engines, models and providers; the configuration
  is one of the ways that catalogue gets filled. This is a breaking rename, in
  a major, on purpose: the ETS table names are unchanged, so only the module
  name moved.
- `Candil.Store.register_engine/1`, `register_model/1` and
  `register_provider/1` validate before writing, and return
  `{:error, reasons}` instead of inserting anyway. `Candil.Model.validate/1`
  existed for the whole 3.x line and nothing called it, so every malformed
  model was accepted and discovered only when the engine refused to start.
- `register_provider/1` accepts a plain string `api_key` again. It used to
  raise, with an error message naming the rule, while the README in the same
  repository documented the plain string. It now returns
  `{:error, reasons}` instead of raising, so a bad config file lists its
  problems rather than crashing the caller.
- New `Candil.Config.Schema`, validating the `candil.toml` document. It returns
  every problem at once rather than the first, because someone fixing a
  config file should not have to run the tool once per typo.
- New `Candil.Config.File` for reading it, honouring `CANDIL_CONFIG`,
  expanding every `~` in a path, and treating a missing file as an empty
  config rather than an error.
- `toml` is a new dependency. `Config.File.save/2` is the one stub; it
  validates before refusing, so a caller gets its schema problems first.

### Fixed
- `Candil.Config.File.expand/1` matched the `source` and `draft` keys as
  atoms while the map came out of TOML with string keys. It compiled, passed
  the empty-document test, and silently did nothing for every real config.
  This is the second time in this phase that an atom/string key mixup wrote
  code that could not fail in the tests that exercised it.

### Added — phase -1: contracts (part 4): Context
- `Candil.Context` and `Candil.Context.Session`. Conversation history shared
  between consumers, keyed by `{consumer, session_id}`.
- `Candil.Context` is in the supervision tree, after `Candil.Store` and
  before the rest, because the other children read its tables.

### Fixed
Three bugs in the new code, all caught by its own tests and all of the same
family: a plausible line that cannot fail in the test that exercises it.

- `gc/1` compared `DateTime.to_unix(last_used_at, :microsecond)` against
  `System.monotonic_time(:microsecond)`. Two different epochs, so the
  comparison was meaningless and the TTL collected nothing, ever.
- The LRU half of `gc/1` computed the excess to remove as
  `max(-(length - max), 0)`. Negating before `max/2` means the negative side
  always wins, so the count was 0 and `Enum.split(sorted, 0)` removed
  nothing. The collection silently never collected anything.
- `Session.tokens/1` used `&div(String.length(&1.content), 4)`, which is a
  unary capture, inside an `Enum.reduce/3` that calls it with two arguments.

### Added — phase -1: contracts (part 5): Router
- `Candil.Router`, `Candil.Router.{Decision, Cache, Consumer, DecisionEngine,
  Scorer}`. Deciding which model answers, in four layers ordered by cost:
  cache, keyword rules, embeddings, LLM classifier. The classifier is off by
  default, because a router that spends a completion to save a tenth of one
  is usually a bad trade.
- `Candil.Router.pin/2` forces a consumer's model, which is how `posadero` and
  `opencode` stop arguing over the same engine while it starts. Pins live in
  this process: per-node, and not surviving a restart, because a pin written
  to disk outlives the reason for it.
- The embedding and LLM layers return `:miss`, not a score. A layer that
  returns a plausible number for something it did not compute routes on noise
  and reports confidence.

### Fixed
- The routing cache key was the prompt hash alone. Two consumers with
  different pins and the same prompt therefore got the same decision, and
  whichever routed first decided for both. That is the exact leak the
  `{consumer, session_id}` partitioning exists to prevent, reappearing one
  layer over. The consumer is now part of the key, with a regression test.
- The rule layer used the same 0.70 confidence threshold as the semantic
  layers. It is a keyword ratio: a real code prompt hits three of eight rule
  words and scores 0.375, so the rule layer could never fire and every prompt
  fell through to the default. Each layer now has its own threshold; a keyword
  ratio and a cosine similarity are not the same kind of number.

### Notes
- The built-in rules are English. A Spanish prompt does not match them. The
  real vocabulary belongs in `[router.rules]` in the config file, and a
  cross-language near miss is not made to match, because that would make the
  score a lie.

### Added — phase -1: contracts (part 6): Gateway
- `Candil.Gateway`, `Candil.Gateway.{Auth, Endpoint}`. An OpenAI-compatible
  HTTP server in front of the catalogue, so `opencode`, `openai-python` or
  `curl` can use Candil without writing Elixir.
- Every route has a `/c/:consumer` prefix as well as a bare form, so one
  gateway can serve several consumers without their configuration colliding.
- `plug` and `bandit` are dependencies.

### Fixed
- `Candil.Gateway.Endpoint.consumer/3` used `String.to_atom/1` on a name taken
  from the URL. The atom table is finite and never shrinks, so an endpoint
  that converts whatever arrives can be made to leak memory at a byte per
  request. It is now `String.to_existing_atom/1`: a consumer that exists was
  defined in the config file, and the config file already made its atom.
- The `Candil.Config` to `Candil.Store` rename had also renamed
  `Candil.ConfigManager` to `Candil.StoreManager`, which is a different
  module doing a different job. Reverted. A blanket string replacement is not
  a rename.

### Notes
- `Gateway.start/1` validates the auth configuration and then returns
  `{:error, :not_implemented}`. It does not return a pid for a server that is
  not listening yet; a caller that waits for a port which never binds is worse
  off than one told up front.
- Auth is `none` or `api_key`, and keys are compared in constant time. JWT is
  not here and does not belong in v4.

### Added — phase -1: contracts (part 7): Context, completed
- `Candil.Context.Builder`, `Candil.Context.Summarizer` and
  `Candil.Context.PrefixManager`. `Candil.Context` itself is the store; these
  are what make a session usable.
- `Candil.Context.Builder.build/3` returns `{:error, :context_exceeded}`
  rather than quietly truncating. A truncated conversation is one where the
  model answers a question it was not asked, with no way for the caller to
  tell. An error is recoverable; a plausible wrong answer is not.
- `Candil.Context.Summarizer` never destroys anything. It writes a summary
  and moves a marker; the messages stay. A summariser that fails halfway
  leaves the session exactly as it was, which is why it summarises before it
  would otherwise delete rather than the other way round.
- `Candil.Context.PrefixManager` exists to make a byte-identical prefix
  possible, not to avoid the transfer. The provider-side KV cache is only
  reusable when the bytes match, and `stats/0` is there so the claim can be
  checked rather than assumed.

### Fixed
- `Builder.build/3` never appended the new messages. It returned the system
  prompt, the summary and the history, and dropped the question that had
  just been asked. That is the worst thing a context builder can do, and the
  test that caught it was the first one written.
- `context_size` was read off the session. The context window belongs to the
  model: one session can be routed to a 4k model and then a 131k one, and the
  window travels with the model, not with the conversation. It is an option
  now.

### Added — phase -1: contracts (part 8): MCP and RAG
- `Candil.MCP` and `Candil.MCP.Protocol`. The protocol revision is
  `2025-11-25`, with the handshake, the `MCP-Protocol-Version` header on HTTP,
  and no JSON-RPC batching, which the specification removed in `2025-06-18`.
  The three previous design documents in this repository all said
  `2024-11-05`, two generations behind.
  `check_http_header/1` and `batch?/1` exist so each rule is checkable without
  a transport.
- `Candil.RAG` and `Candil.RAG.Chunk`, with `rrf/2` and `cosine/2`
  implemented rather than stubbed. RRF uses the **rank** of a document, not
  its score, because BM25 and cosine produce numbers on scales that were
  never comparable and a miscalibrated sum silently favours one system.

### Fixed
- `Candil.RAG.embedder/1` returned the string straight out of the config
  file, and `Candil.Store` is keyed by atoms. Every configured embedder would
  have missed every lookup, and the failure would have looked like a missing
  model rather than a type mismatch.
- `String.to_existing_atom("")` succeeds and returns `:""`, so an empty
  `embedder` resolved to a model alias that matches nothing, through the one
  lookup that should have rejected it.

## [3.0.0] - 2026-09-18

### Added — FASE-3 (candil 3.0)
- `Candil.Backend` behaviour (`chat/3`, `chat_stream/3`, `embed/3`,
  `models/0`) with auto-registration for local (LlamaCpp) and remote
  (OpenAI-compat: openai, anthropic, ollama, azure) providers.
- `Candil.Tool` registry + `Candil.Tools` parser: define/list/call tools,
  `<|tool_call|>` local parsing, OpenAI `tool_calls` wire format,
  JSON-schema validation of args.
- `Candil.Structured.complete/4`: structured outputs with JSON-schema
  validation and retry with validation feedback.
- `Candil.Agent`: minimal ReAct loop over tools (`use Candil.Agent`,
  stop word, max_steps, cancellation support, trace).
- `Candil.Cancellation` GenServer: register/done/cancel refs for
  in-flight streams.
- `Candil.Telemetry`: `[:candil, :inference, :start|:stop|:token|:error]`,
  `[:candil, :cost, :estimate]`, `[:candil, :cancellation]`.
- `Candil.Cost.estimate/4` with per-model pricing + telemetry.
- Robust stateful SSE parser in `Candil.Stream` (arbitrary chunk
  splits, CRLF/LF/mixed terminators, comment lines, mailbox backpressure).
- `Candil.Embeddings.embed_batch/2` with real batching (`batch_size`,
  default 32).
- Normalized error semantics: `Candil.Error` reason kinds
  (`:auth_error`, `:server_error`, `:rate_limited`, `:cancelled`,
  `:backend_unavailable`) via `http_error/2` status classification.
- Per-word token estimation in `Candil.Conversation.TokenEstimator`
  (replaces 4-chars-per-token; legacy kept as `estimate_content_legacy/1`).
- `Candil.Conversation.add_message/3` without a backend call (agent loops).

### Fixed
- `Candil.Backend.OpenAICompat` request body built correctly when opts
  arrive as keyword lists (`Map.put` → `Keyword.put`).
- `Candil.Stream.do_stream` initial state includes `:error` field.
- `TokenEstimator.estimate_conversation/1` accumulator argument order.
- Test isolation: `Candil.Tool.reset/0`, cancellation count assertions
  relative to pre-test state, deterministic Mox adapter for all tests.
- Preserved successful HTTP response maps and corrected their Dialyzer typing.
- Sent health-check embedding payloads as maps accepted by the shared HTTP client.
- Rejected unknown string config keys without creating atoms at runtime.
- Replaced live GitHub calls in detector tests with the configured mock HTTP adapter.

### Changed
- Updated English and Spanish README dependency, API arity, and architecture examples.
- `mix.exs`: sibling deps are now Hex requirements
  (`{:apero, "~> 4.0"}`, `{:arrea, "~> 3.0"}`); `source_ref` points
  at `3.0.0`.

## [2.1.0] - 2026-07-11

### Added
- `Candil.Engine.Launcher` behaviour for custom engine launchers (external
  processes, systemd units, docker containers).
- `Candil.Engine.Server.External` GenServer for managing engines whose
  lifecycle is handled outside Candil.
- `Candil.EnginePool` LRU pool to track and manage engine usage.
- `:launcher` field in `Candil.Engine` struct.

### Changed
- `Candil.Engine.Server` now delegates port management to
  `Arrea.LongRunning` instead of opening ports directly. Adds automatic
  supervision, registry, telemetry, and graceful shutdown. Polling interval
  raised from 500ms to 5s (responsiveness is now driven by telemetry events
  + on-demand health checks).

## [2.0.0] - 2026-07-07

This entry consolidates everything between `1.0.0` and the current
HEAD — including the `Candil.Health` / `ConfigManager` / `Embeddings`
migration from `Apero.Llm.*`, the production hardening pass, the
`Candil.Retry` removal, the `source_ref` sweep, and the dialyzer fix
in `ConfigManager`. The `0.2.0` and `0.3.0` versions in earlier
CHANGELOG drafts were planning milestones only — they have no
corresponding git tags and have been collapsed into this single
canonical `2.0.0` entry.

### Added
- **`Candil.Health`** — provider health probes (ping, probe) migrated
  from `Apero.Llm.Health`.
- **`Candil.ConfigManager`** — config validation and normalization for
  LLM and embedding providers, migrated from `Apero.Llm.ConfigManager`.
  Complements `Candil.Config` (ETS registry) by handling raw map-based
  config.
- **`Candil.Embeddings`** — embedding generation abstraction for
  ollama, local, and OpenAI-compatible providers, migrated from
  `Apero.Llm.Embeddings`.
- **`Candil.Provider`** struct (`lib/candil/provider.ex`) that
  encapsulates remote LLM provider configuration: name, base_url,
  api_key, default model, max_tokens, and provider-specific options.
  Replaces the previous pattern of passing raw keyword lists to
  `Candil.Client.chat/3`.
- **`Candil.Cost`** — cost estimation for LLM API usage with pricing
  table for OpenAI, Anthropic, and local models.
- **`Candil.Application`** — OTP application with ETS-based config and
  DynamicSupervisor for engine management.
- **Function calling (tools)**: pass a list of tool definitions in
  `:tools` opt, response includes `tool_calls` key with parsed
  arguments. Supported in OpenAI and Anthropic builders.
- Tests for the new modules: `test/candil/cost_test.exs`,
  `test/candil/request_builder_test.exs`, and integration coverage of
  `Candil.Provider` and the registry lifecycle.

### Changed
- **`chat_remote/4` refactored**: collapsed 5 pattern-match clauses
  into a single function with `build_request_body/4` and
  `response_parser/1` dispatch. Adding a new provider is now a 2-line
  change.
- Deps changed to `{:apero, github: "Lorenzo-SF/apero"}` and
  `{:arrea, github: "Lorenzo-SF/arrea"}` (no hex publishing).
- Mix.exs adds doc groups_for_modules, dialyzer_config, and a new
  `CHANGELOG.md`.

### Fixed
- **`Candil.Registry`**: now started in `Candil.Application` —
  previously it was only created in `test_helper.exs`, causing
  `Candil.Engine.Server.start_link/1` to crash in production with
  `"Candil.Registry not started"`.
- **`Candil.ConfigManager.validate/1`** — the validation helpers built
  improper lists (`[errors | "string"]`), so when `validate/1`
  encountered more than one error the accumulated state was a binary,
  not a `[String.t()]`. The contract on the public function is
  `{:error, [String.t()]}` and dialyzer flagged the helpers with
  `improper_list_constr`. Switched all four cons-sites to `errors ++
  ["..."]` so the accumulator is always a proper list.
- **`source_ref`** in `mix.exs` now points to the canonical `2.0.0`
  tag (was pointing at a non-existent `v0.3.0` tag). The dangling
  `v0.2.0` link in the CHANGELOG footer was also dropped.

### Removed
- **`lib/candil/provider/`** directory (5 files, 753 lines, dead
  code: never called by the dispatch).
- **`lib/candil/engine/behaviour.ex`** (99 lines, 0 implementers).
- **`Candil.Retry`** (unused — `Apero.Retry` is the canonical retry
  helper now).
- **`lib/apero/llm/`** directory — `Health`, `ConfigManager`,
  `Embeddings` were originally placed in `Apero.Llm.*` but belong in
  Candil (the LLM domain). They live here now.

## [1.0.0] - 2026-06-10

### Added
- Initial open source release: local llama.cpp engine,
  OpenAI/Anthropic/Ollama remote providers, conversation, streaming,
  embeddings.

[3.0.0]: https://hex.pm/packages/candil/3.0.0
[2.1.0]: https://hex.pm/packages/candil/2.1.0
[2.0.0]: https://hex.pm/packages/candil/2.0.0
[1.0.0]: https://hex.pm/packages/candil/1.0.0
[Unreleased]: https://github.com/Lorenzo-SF/candil/compare/3.0.0...HEAD


> ## A note on versioning
>
> The only canonical tags are `1.0.0` (initial open-source cut-over),
> `2.0.0`, `2.1.0` and `3.0.0` (current HEAD). The `[0.2.0]` and
> `[0.3.0]` headers in earlier drafts were **planning milestones**,
> not releases: they have no corresponding git tags. Earlier `0.x`
> versions are no longer maintained and have been collapsed into the
> single canonical `2.0.0` entry. `mix.exs` `version` reflects the
> current development state and may be ahead of the public surface.
> Pin to a released tag for stable dependencies.

> ## A note on history
>
> The git history of this repository was rewritten as part of a
> deliberate cleanup effort. The commits you can read describe the
> codebase as it stands today — they do not preserve the original
> chronology of development.
>
> Anything worth keeping from before the rewrite was carried forward
> as tagged releases with explicit `CHANGELOG.md` entries. Anything
> not preserved is, by the maintainer's choice, no longer part of
> the canonical development line.
>
> Tag `1.0.0` points to the initial open-source cut-over; tags
> `2.0.0`, `2.1.0` and `3.0.0` point to their respective releases.
> All versioned artifacts on Hex.pm and GitHub Releases
> follow this convention.