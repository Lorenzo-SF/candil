# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.1.0] - 2026-XX-XX

### Added
- `Candil.Engine.Launcher` behaviour for custom engine launchers (external
  processes, systemd units, docker containers).
- `Candil.Engine.Server.External` GenServer for managing engines whose
  lifecycle is handled outside Candil.
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

[2.0.0]: https://hex.pm/packages/candil/2.0.0
[1.0.0]: https://hex.pm/packages/candil/1.0.0


> ## A note on versioning
>
> The only canonical tags are `1.0.0` (initial open-source cut-over)
> and `2.0.0` (current HEAD). The `[0.2.0]` and `[0.3.0]` headers
> in earlier drafts were **planning milestones**, not releases: they
> have no corresponding git tags. Earlier `0.x` versions are no longer
> maintained and have been collapsed into this single canonical
> `2.0.0` entry. `mix.exs` `version` reflects the current development
> state and may be ahead of the public surface. Pin to `1.0.0` or
> `2.0.0` for stable dependencies.

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
> Tag `1.0.0` points to the initial open-source cut-over; tag
> `2.0.0` points to the current HEAD and the canonical consolidated
> release. All versioned artifacts on Hex.pm and GitHub Releases
> follow this convention.