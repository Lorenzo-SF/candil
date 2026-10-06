# Auditoría de `ElPaso` para la migración a Candil — 2026-10-06

> **Qué es esto.** Un análisis del motor de decisión de `ElPaso` (`Lorenzo-SF/elpaso`,
> commit `4c481fb`) hecho antes de migrarlo a Candil, para no traerse sus errores
> ni perder lo que tiene bien. **Solo análisis**: no se ha tocado `elpaso`.
>
> **El hallazgo de fondo:** el router de Candil que llevamos días construyendo es
> una reimplementación **parcial** de `ElPaso.Domain.DecisionEngine`, que ya
> existe, tiene 859 líneas y lleva años en producción. Casi todas las decisiones
> que llevamos horas arrastrando aquí ya estaban contestadas en ese código.

---

## 1. El alcance real del solapamiento

```
lib/el_paso/domain/decision_engine.ex                  145
lib/el_paso/domain/decision_engine/decision_cache.ex    87
lib/el_paso/domain/decision_engine/embedding_matcher.ex 118
lib/el_paso/domain/decision_engine/llm_classifier.ex   131
lib/el_paso/domain/decision_engine/scorer.ex           130
lib/el_paso/domain/router.ex                           248
                                                    ──
                                                     859 líneas
```

Son las **cuatro capas** que la fase 7 §19.2 describe, y en el mismo orden que
implementamos: keyword → embeddings → LLM → default, con caché ETS delante.

| Capa | ElPaso | Candil |
|---|---|---|
| Caché | `DecisionCache` (ETS) | `Router.Cache` |
| Keywords | `Scorer` | `Router.Scorer` |
| Embeddings | `EmbeddingMatcher` | `decide_by(:embedding)` |
| LLM | `LLMClassifier` | `decide_by(:llm)` |
| Default | `fallback_to_default/2` | `finish(:miss, ...)` |

---

## 2. §3.2 — el vocabulario: ya estaba resuelto, y mejor que lo nuestro

Esto contesta la pregunta que llevaba **horas**: «¿qué palabras van con qué
modelo?».

**El scorer de ElPaso no tiene una lista de palabras en el código.** Las lee de
la personalidad, en base de datos:

- `trigger_keywords` (n-gram aware)
- `regex_patterns`
- prioridad de la personalidad

Y el confidence **no es «palabras que han casado sobre palabras que tiene»**, sino
el score normalizado contra lo que *esa* personalidad podía haber conseguido:

```elixir
max_possible = max_possible_score(personality)
confidence = Float.round(raw_score / max_possible, 3)
```

### Por qué esto importa más que cualquier lista de palabras

Candil puntúa `matched / total_words_of_the_rule`. Sobre un prompt real del
usuario eso da **0.125**, por debajo del umbral de 0.20, y no enruta nada.

El normalizado de ElPaso no tiene ese problema: una personalidad con cuatro
palabrasTrigger y que casa con dos da **0.5**, que es información sobre ella
misma, no sobre el prompt. Y si un día añades una palabra a una personalidad,
el umbral no se descuadra porque el denominador se mueve con ella.

**Conclusión: §3.2 no es «inventar un vocabulario». Es «poner el vocabulario
donde lo tenía ElPaso», que es datos, no código.** Y el único tramo que se
puede detectar por firma sigue siendo `TD-\d+`, que es lo que acordamos.

---

## 3. §3.3 y §3.4 — aquí ElPaso hace lo CONTRARIO de lo decidido

Esto es lo más importante de la auditoría, y va contra lo que hemos
implementado hoy mismo.

### §3.3 · embeddings caídos

```elixir
{:error, _reason} ->
  # Embedding falló → intentar LLM o default
```

Cae a la siguiente capa **y no dice nada**. El `metadata` que sale tiene
`layer:`, `confidence:` y `matched_trigger:`, pero **no registra que la capa de
embeddings no corrió**. Dos decisiones con el mismo 0.55 —una medida y otra
fallida— son indistinguibles para quien lee el resultado.

Es exactamente el fallo que arreglamos hoy con `degraded:` y `confidence:` en
el `Decision`. **La decisión del dueño es mejor que ElPaso, y la migración es la
oportunidad para aplicarla.**

### §3.4 · clasificador LLM caído

```elixir
_ ->
  # ── Capa 4: Default fallback ─────────────
  fallback_to_default(personalities, content)
```

Cualquier cosa que no sea un `{:ok, %{personality: p}}` con `p` no nulo —incluido
un modelo caído, un timeout o una excepción— cae al default **sin decir por
qué**.

Coincide con la decisión que tomamos («reventar informando»), y de nuevo la
migración es el sitio de aplicarlo.

---

## 4. El bug que Candil ya arregló y ElPaso **sigue teniendo**

`DecisionCache` indexa **solo por el contenido**:

```elixir
defp hash_content(content) do
  ElPaso.Ecosystem.crypto_hash(:sha256, String.downcase(content)) || :erlang.phash2(content)
end
```

Sin consumer, sin pin, sin nada de contexto. Dos consumidores distintos con el
mismo prompt: **el que enrutó primero decide por los dos.**

Y esto no es una hipótesis, es la nota que ya está escrita en
`Candil.Router.Cache`:

> *«The consumer is part of the key. It has to be. […] la key del prompt sola
> significa que el consumidor que rutió primero decide por todos. Ese es
> exactamente el leak que existe para que la entrada que rutió primero decida
> por todos.»*

**Conclusión: el bug está vivo hoy en ElPaso.** Y es la clase de cosa que no se
ve en un smoke porque el router «funciona», devuelve rápido, y son decisiones de
otro.

---

## 5. El acoplamiento que Candil ya rompió

`DecisionEngine` empieza así:

```elixir
active = PersonalityManager.list_active()
```

Todo modelo viene de **Ecto**. La decisión de enrutado —que debería ser una
función pura sobre el catálogo— está atada al gestor de personalidades y a la
base de datos. `Candil.Router` existe justamente para cortar eso: la unidad es
un `Candil.Model` y el catálogo es `Candil.Store`, y «nothing in this module
knows what a database is».

**Conclusión: aquí Candil es estrictamente mejor, y no hay que farmacia-copiar nada de ElPaso.**

---

## 6. Resumen de conclusiones

| | Qué hacer |
|---|---|
| **Traer** | La normalización del confidence contra `max_possible_score`. Es lo que hace que las reglas funcionen sobre prompts conversacionales, y es la respuesta a §3.2 |
| **Traer** | El vocabulario como **datos** (trigger_keywords, regex_patterns por personalidad), no como constantes en el módulo |
| **No traer** | El fallback silencioso de embeddings ni el del clasificador LLM. Se quedan con `degraded:` y con el error que reventan |
| **No traer** | La clave de caché sin consumer. Ya está arreglado en Candil y hay que mantenerlo |
| **No traer** | El acoplamiento con `PersonalityManager` / Ecto |
| **Revisar luego** | Los umbrales `0.70` y `0.55`, que están pensados para un score normalizado y **no** para la ratio `matched / total` que usa Candil hoy. Copiarlos tal cual sería copiar un número que significa otra cosa |

Lo de los umbrales es el punto que más fácil se cuela: **si se copian el 0.70 de
ElPaso sin copiar su denominador, el router deja de enrutar del todo** y parece
que funciona.

---

## 7. Lo que este análisis NO cubre

- Los pesos de `TaskCategories`, que sería lo siguiente que mirar.
- El resto del motor de ElPaso (`EngineManager`, `ModelManager`,
  `dispatcher`), que es donde habrá más solapamiento con `Candil.Engine`.
- Si posadero hereda este motor tal cual o lo reescribe: eso se decide cuando
  lleguemos a posadero, no aquí.
