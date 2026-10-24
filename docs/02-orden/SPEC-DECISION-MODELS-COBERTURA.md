# Spec de tarea: Integración de modelos de decisión como cobertura para `:degrade` (P-1, quinta vía)

## Stack y versiones (literal)
- Elixir 1.19, OTP 28
- Repo: `/home/lorenzo/workspace/github/zaguan/candil`
- Branch de trabajo: `docs/carril-0-contrato-y-plan` (base `main` `e5bde10`)
- Motor local: `llama-server` build 11860 (endpoint `/v1/systemone` verificado en el binario)
- Modelos candidatos (ggml-org): `Laya-GGUF` (0.4B), `lev-GGUF` (4B), `OpenJev-GGUF` (27B)

## Contexto del proyecto
- `:degrade` está declarado en `Candil.Refusal` (`refusal.ex:99`) pero es inalcanzable (`:191-195`).
- La opción (1) del P-1 solo tiene sentido si el enrutado sabe **qué pide la pregunta** (cobertura).
- Un modelo de decisión de `llama.cpp` (`/v1/systemone`) devuelve probabilidades sobre una lista de opciones en una sola pasada, con `output_tokens: 0`, sin API y sin salir de la máquina.
- Ninguno de esos modelos está en el catálogo de Candil todavía.
- Cualquier modelo nuevo debe pasar por la reserva de VRAM (D-28).

## Archivos existentes a REUTILIZAR (no reimplementar)
- `lib/candil/refusal.ex:99,191-195` — `:degrade` y su `ArgumentError`.
- `lib/candil/router/scorer.ex` — capas de enrutado (`:rule`, `:embedding`, `:llm`).
- `lib/candil/model.ex` — catálogo y `file_path/1`.
- `lib/candil/engine/resource.ex` — reserva de VRAM.
- `lib/candil/provider.ex` — integración con motores.
- `lib/candil/config/schema.ex` — secciones del TOML.

## Dónde encaja en el router (y por qué no es «una capa más»)

`Candil.Router.Scorer` tiene tres capas ✓ (`scorer.ex:70` ✓):

```elixir
@type layer :: :rule | :embedding | :llm
```

Y la que da la **cobertura** ya existe ✓: la capa **`:embedding`** ✓ compara
el prompt con la `description` de cada modelo ✓ por similitud del coseno ✓
(`scorer.ex:419` ✓).

**Y esa capa es la que se queda sin embedder** ✓: sin un embedder ✓ no hay
vectores ✓ y la comparacion no se puede hacer ✓. La capa **`:embedding`** es
exactamente la cobertura que `:degrade` necesita ✓, y es la que hoy **no
funciona** ✓ porque el embedder esta retirado ✓.

Un modelo de decision hace **ese mismo trabajo** ✓ —«de estas opciones ✓,
cual cubre esta pregunta?» ✓— con otro mecanismo ✓: una pasada ✓, sin
embeddings ✓, sin API ✓ y sin coste por llamada ✓.

Por eso esta via **no es una quinta capa del scorer** ✓ —eso seria el
`Candil.Decision` de mas abajo ✓— sino **la misma capa `:embedding` con otro
motor debajo** ✓:

- Con embedder ✓: vectores ✓, coseno ✓, y la distancia compara texto con
  texto ✓ ✓.
- Con modelo de decision ✓: probabilidades ✓ sobre las opciones ✓, que son
  las mismas descripciones ✓ ✓.

Y por eso esta via **tambien es una cuarta salida para la decision del
embedder** ✓: **restaurar un embedder** ✓, **un proveedor remoto** ✓, **degradar
y documentarlo** ✓, o **usar un modelo de decision en su lugar** ✓ ✓ —que es
esta ✓.

## Preguntas abiertas (decisión del dueño)

### 1. Dónde vive
- **Opción A**: un modelo más del catálogo (`[model.decision]` con `kind = "decision"`), con reserva de VRAM y ciclo de vida normal.
- **Opción B**: un servicio aparte que no compite por la GPU (proceso o endpoint dedicado).

**Recomendación del consejero**: Opción A, porque reutiliza el catálogo, la reserva y el provider; la Opción B duplica infraestructura. Si la VRAM es el cuello de botella, se decide con medición, no por adelantado.

### 2. Cómo se llama
- **Opción A**: `Candil.Decision` que envuelve `/v1/systemone`.
- **Opción B**: una capa nueva en `Candil.Provider` (`decide/3`).

**Recomendación del consejero**: Opción A como fachada, delegando en el provider para el transporte. El provider no debe saber de cobertura; solo de cómo llamar al motor.

### 3. Qué se hace con la salida
- El modelo devuelve probabilidades, no una elección.
- Quien decide el umbral: el router (configurable en TOML, con default razonable).
- Si ninguna opción pasa el umbral: se trata como `:no_models_for_consumer` (no como `:degrade`), porque no hay candidato válido.

**Recomendación del consejero**: umbral configurable con default 0.5; si ninguna pasa, `:fail` (no degradar a un modelo que no cubre).

### 4. El gasto
- Un modelo más en la GPU es VRAM que el resto no tiene.
- Debe pasar por `Candil.Engine.Resource` (reserva + medición real).
- Si no cabe, el refusal actúa como con cualquier otro modelo.

## Cambios concretos (una vez firmada la decisión)

1. `lib/candil/decision.ex` — nuevo módulo `Candil.Decision`:
   - `@spec decide([binary()], map()) :: {:ok, [{binary(), float()}]} | {:error, term()}`
   - llama a `/v1/systemone` con las opciones y devuelve probabilidades ordenadas.

2. `lib/candil/router/scorer.ex` — la capa **`:embedding`** ✓, que es la de
   cobertura ✓, **cambia su motor** ✓ por el modelo de decision ✓ —o una
   capa `:decision` aparte ✓, si el dueno prefiere no tocar la existente ✓:
   - recibe las opciones del router ✓ (las `description` de los candidatos ✓)
     y el estado ✓;
   - llama a `Candil.Decision.decide/2` ✓;
   - filtra por umbral ✓ y devuelve el mejor candidato ✓ o
     `:no_models_for_consumer` ✓.

   **Que el mecanismo sea reemplazable** ✓ es lo que hace que esto no sea un
   commitment ✓: la capa decide **que** comparar ✓, el mecanismo decide **como**
   ✓.

3. `lib/candil/config/schema.ex`:
   - añadir `kind = "decision"` como valor válido en `[model.*]`.

4. `lib/candil/config/template.ex`:
   - sección comentada para modelo de decisión.

5. Tests:
   - `test/candil/decision_test.exs` con mock del endpoint.
   - `test/candil/router/decision_test.exs` con umbral y sin candidatos.

## Constraints duros (NO violar)
- NO añadir dependencias nuevas.
- NO tocar `Candil.Refusal` hasta que la cobertura exista (P-1 sigue siendo decisión).
- NO implementar sin medir VRAM real.
- El modelo de decisión es un modelo más: pasa por reserva y por el scheduler.

## Verificación esperada
```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test test/candil/decision_test.exs test/candil/router/decision_test.exs
mix dialyzer
```

## Acceptance criteria
- [ ] `Candil.Decision.decide/2` llama a `/v1/systemone` y devuelve probabilidades.
- [ ] El router usa la cobertura cuando está configurada.
- [ ] Si ninguna opción pasa el umbral, se devuelve `:no_models_for_consumer`.
- [ ] El modelo de decisión pasa por la reserva de VRAM.
- [ ] `mix test` pasa con 0 fallos.

## Lo que NO debe hacer el ejecutor
- NO implementar `:degrade` todavía (eso es P-1, decisión separada).
- NO elegir el modelo por el ejecutor (es decisión del dueño).
- NO tocar `Candil.Refusal`.

## Lo que NO deben hacer qa y reviewer
- NO suavizar fallos.
- NO modificar código de producción.
- `qa` debe marcar cada AC con ✅/❌/⚠️ y justificar.
- `reviewer` debe reportar findings con severidad, ruta/línea, impacto y corrección concreta.

## Relación con P-1
Este spec es la **quinta vía** del P-1: el camino que hace alcanzable la opción (1) (implementar `:degrade` de verdad). No la implementa; la hace posible.
