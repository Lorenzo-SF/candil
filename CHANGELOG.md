# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `Candil.Health` — provider health probes (ping, probe) migrated from `Apero.Llm.Health`.
- `Candil.ConfigManager` — config validation and normalization for LLM/embedding providers,
  migrated from `Apero.Llm.ConfigManager`. Complements `Candil.Config` (ETS registry)
  by handling raw map-based config.
- `Candil.Embeddings` — embedding generation abstraction for ollama, local, and
  OpenAI-compatible providers, migrated from `Apero.Llm.Embeddings`.

### Fixed
- `Candil.Registry` is now started in `Candil.Application` — previously it was only
  created in `test_helper.exs`, causing `Candil.Engine.Server.start_link/1` to crash
  in production with `"Candil.Registry not started"`.

## [0.3.0] - 2026-06-27

### Added
- New `Candil.Provider` struct (in `lib/candil/provider.ex`) that
  encapsulates remote LLM provider configuration: name, base_url,
  api_key, default model, max_tokens, and provider-specific options.
  Replaces the previous pattern of passing raw keyword lists to
  `Candil.Client.chat/3`.

### Changed
- Bumped version to 0.3.0 to tag the release that includes the
  `Candil.Provider` struct. Pre-v0.3.0, downstream consumers using
  `%Candil.Provider{}` would fail to compile with
  `Candil.Provider.__struct__/1 is undefined`.

## [0.2.0] - 2026-06-24

## [0.2.0] - 2026-06-24

### Added
- `Candil.Cost` — cost estimation for LLM API usage with pricing table for OpenAI, Anthropic, and local models.
- `Candil.Application` — OTP application with ETS-based config and DynamicSupervisor for engine management.
- **Function calling (tools)**: pass a list of tool definitions in `:tools` opt, response includes `tool_calls` key with parsed arguments. Supported in OpenAI and Anthropic builders.
- Tests for the new modules: `test/candil/cost_test.exs`, `test/candil/request_builder_test.exs`.

### Changed
- **i18n**: documented the existing English-only public surface under Project history and linked the 1.0.0 release to hex.pm.
- **`chat_remote/4` refactored**: collapsed 5 pattern-match clauses into a single function with `build_request_body/4` and `response_parser/1` dispatch. Adding a new provider is now a 2-line change.
- Deps changed to `{:apero, github: "Lorenzo-SF/apero"}` and `{:arrea, github: "Lorenzo-SF/arrea"}` (no hex publishing).
- Mix.exs adds doc groups_for_modules, dialyzer_config, and a new `CHANGELOG.md`.

### Removed
- `lib/candil/provider/` directory (5 files, 753 lines, dead code: never called by the dispatch).
- `lib/candil/engine/behaviour.ex` (99 lines, 0 implementers).

## [1.0.0] - 2026-06-10

### Added
- Initial open source release: local llama.cpp engine, OpenAI/Anthropic/Ollama remote providers, conversation, streaming, embeddings.

[1.0.0]: https://hex.pm/packages/candil/1.0.0

[0.2.0]: https://github.com/Lorenzo-SF/candil/releases/tag/v0.2.0
