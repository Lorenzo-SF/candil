# Spec de tarea: M-1 · `Candil.Tool` deja de ser un registro a medias

## Stack y versiones (literal)
- Elixir 1.19, OTP 28
- Repo: `/home/lorenzo/workspace/github/zaguan/candil`
- Branch de trabajo: `docs/carril-0-contrato-y-plan` (base `main` `e5bde10`)

## Contexto del proyecto
- `Candil.Tool` es un `GenServer` que registra tools (`lib/candil/tool.ex`).
- `__using__/1` pone `@behaviour unquote(__MODULE__)` (`tool.ex:64`), pero el módulo no declara ningún `@callback`.
- `validate_args/2` existe (`tool.ex:133-146`) pero `call/2` (`:114-122`) no lo llama.
- `lib/candil/mcp/tool.ex` sí tiene callbacks; el hueco está en el registro genérico.
- `Candil.MCP.Server` ya usa `Tool.list/0` y convierte excepciones en `-32603` (`server.ex:123-154`).

## Archivos existentes a REUTILIZAR (no reimplementar)
- `lib/candil/tool.ex:47-54` — `defstruct` y `@type t`.
- `lib/candil/tool.ex:56-75` — `__using__/1`, donde ya está `@behaviour`.
- `lib/candil/tool.ex:114-122` — `call/2`, donde hay que insertar la validación.
- `lib/candil/tool.ex:133-146` — `validate_args/2`, ya implementado y probado.
- `test/candil/tool_test.exs:62-88` — tests existentes de `validate_args/2`.

## Cambios concretos

1. `lib/candil/tool.ex` — añadir el callback:
   - `@callback run(map()) :: {:ok, term()} | {:error, term()}` junto a `@type t`.
   - documentar que `use Candil.Tool` exige `run/1`.

2. `lib/candil/tool.ex` — `call/2`:
   - antes de `function.(args)`, obtener el tool completo con `fetch/1`;
   - llamar a `validate_args/2`;
   - si devuelve `{:error, _}`, devolver ese error sin ejecutar;
   - si devuelve `:ok`, ejecutar `function.(args)`.

3. `lib/candil/tool.ex` — doctest o comentario:
   - dejar claro que un `run/1` mal escrito falla al compilar o al ejecutar.

4. Tests:
   - añadir test de que `call/2` no ejecuta si faltan `required`;
   - añadir test de que un módulo con `run/1` mal tipado falla (compile o runtime);
   - mantener los tests existentes de `validate_args/2`.

## Constraints duros (NO violar)
- NO añadir dependencias nuevas.
- NO cambiar `Candil.Tool.t` ni `define/1`, `list/0`, `reset/0`.
- NO tocar MCP transport, protocolo ni servidor.
- NO cambiar el comportamiento de tools sin `required`.

## Convenciones del repo
- Conventional Commits.
- `@spec` + `@doc` en funciones públicas.
- Cambios pequeños y reversibles.

## Verificación esperada
```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test test/candil/tool_test.exs
mix dialyzer
```

## Acceptance criteria
- [ ] `lib/candil/tool.ex` declara `@callback run(map()) :: {:ok, term()} | {:error, term()}`.
- [ ] `call/2` llama a `validate_args/2` antes de ejecutar.
- [ ] Un tool con args inválidos devuelve `{:error, %Candil.Error{reason: :invalid_request}}` sin ejecutar.
- [ ] Un `run/1` mal escrito falla (compilación o ejecución).
- [ ] Los tests existentes siguen pasando.

## Lo que NO debe hacer el ejecutor
- NO implementar HTTP, cliente ni endurecimiento de M-6.
- NO cambiar `Candil.MCP.Server`.
- NO tocar el protocolo.

## Lo que NO deben hacer qa y reviewer
- NO suavizar fallos.
- NO modificar código de producción.
- `qa` debe marcar cada AC con ✅/❌/⚠️ y justificar.
- `reviewer` debe reportar findings con severidad, ruta/línea, impacto y corrección concreta.
