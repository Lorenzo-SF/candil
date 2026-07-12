# Plan for `@candil` (LLM Inference & Model Management)

> **Goal** – Incorporate a simple LRU pool manager for engines, enforce naming conventions for plug‑ins, and expand the existing test suite for model loading and inference flows.

---

## 1. Preparation

| Step | Action | Outcome |
|------|--------|---------|
| 1.1 | Ensure `fix-tools-domains` is current |
| 1.2 | Ensure the working tree is clean (commit any in‑progress changes before starting) |
| 1.3 | `mix deps.get` – local paths for all peers | Dependencies verified |
| 1.4 | Confirm `candil/mix.exs` contains `path:` overrides |

## 2. Implementation

| Target | Task |
|--------|------|
| **Engine Pool** | Introduce `Candil.EnginePool` with `start_link/0`, `get/0` (LRU selection), `put/1` and `evict/0`. |
| **Engine API** | Modify `Candil.Engine` to register itself with the pool on start.
| **Naming** | Ensure all back‑ends (`Apero`, `Arrea`, `Trebejo`) are referenced via `path:` and have their `generate_*` functions exported.
| **Docs** | Add a short section in `README.md` explaining the pool behavior. |

## 3. Tests

| Test File | Coverage Goal | Key Checks |
|-----------|---------------|------------|
| `test/candil/engine_pool_test.exs` | 100 % | • LRU ordering
| | | • No memory leaks
| `test/candil/inference_test.exs` | 100 % | • Models load correctly across back‑ends
| | | • Inference with small vectors works

Run `mix test --cover`.

## 4. Documentation

* `CHANGELOG.md` – entry ``Adding engine pool for cache and LRU``.
* Update docs page to highlight engine lifecycle.

## 5. Quality

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict --format=json
mix test --cover
mix dialyzer
```

## 6. Commit & Push

```bash
git add -A
git commit -m "Add LRU engine pool and extend tests for candil"
git push origin fix-tools-domains
```

---

**End of plan for `@candil`**