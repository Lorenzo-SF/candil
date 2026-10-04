# Fase 7 — Router


> **Para probar esta fase**: [`../PRUEBAS-MANUALES.md`](../PRUEBAS-MANUALES.md) — comandos, comportamiento esperado y el script `scripts/manual-check.sh`.

> Estado: **pendiente**. Depende de la 6. Carril D.
> Original: `../original/candil-4.0-final.md` §19 y la Fase 7 (~línea 2280).

## Qué es

Las cuatro capas de `§19.2`, con el motor arrancado si hace falta. El router
decide **qué modelo responde** a una petición: no es un balanceador, es una
decisión con criterio y razones.

## Por qué aquí

Está en la ruta crítica porque es lo que hace que `model: "auto"` signifique
algo. Sin él, el gateway de la 8 no puede enrutar y el de la 6 no puede elegir
contexto.

Depende de la 6: un router que reparte sin contexto reparte bien, y uno que
reparte con el contexto equivocado reparte peor. La 6 va antes **a
propósito**.

## Dónde

| Qué | Dónde |
|---|---|
| Módulos | `lib/candil/router.ex` y `lib/candil/router/**` |
| Tests | `test/candil/router/**` |
| Ya existe | `Router`, `Router.Cache`, `Router.Consumer`, `Router.DecisionEngine`, `Router.Scorer` — congelados en la −1, con cuerpo |

**Carril D.** No toques `context/**`, `gateway/**`, `mcp/**` ni `rag/**`.

## Qué hay que hacer

Las cuatro capas, en orden:

1. **`pin/2`** — un modelo fijado gana a cualquier regla.
2. **Reglas** — patrones sobre la entrada. `score` por modelo.
3. **Embeddings** — similitud con la descripción del modelo. **No corre sin un
   modelo de embeddings**: si no lo hay, la capa se salta, no falla.
4. **Clasificador LLM** — una llamada a un modelo pequeño. Opt-in:
   `enable_llm_classifier: false` por defecto. Una petición en la ruta
   caliente no puede depender de otra llamada a un LLM por defecto.

Y `Router.Cache` por consumidor. La clave de caché **incluye el consumer**:
la entry que ruteara primero decidía por todos. Ese bug ya se cometió una vez.

## Cómo se comprueba

```bash
mix test test/candil/router/
#   - property: misma entrada + mismo cache → misma decisión
#   - pin/2 gana a las reglas
#   - sin candidatos → {:error, :no_models_for_consumer}
#   - la capa 2 no corre sin modelo embeddings
#   - la capa 3 no corre con enable_llm_classifier: false
```

El primer caso es un **property test**, no un ejemplo: la misma entrada con la
misma caché tiene que dar la misma decisión, siempre. Es la propiedad que
hace fiable un router.

Más la salida real, que es el criterio:

```bash
$ ./candil router test "refactoriza este módulo de Elixir"
→ coder (rule, score 0.80)
  alternativas: verifier 0.20, gpt4o 0.00

$ ./candil router stats
consumer    model      calls   p50      p95      errors
opencode    coder      128     820ms    3.1s     2
posadero    embed      47      12ms     40ms     0
```

`router stats` con p50/p95 y errores es lo que convierte el router en algo que
se puede operar en vez de algo en lo que se cree.

## Por qué NO

- **No un LLM que decida siempre.** Por defecto son reglas y caché. Un LLM en
  la ruta caliente multiplica la latencia y el coste por una decisión que
  cuatro patrones resuelven.
- **No balanceo de carga.** El router elige por **qué modelo toca**, no por
  cuál está menos ocupado. Son preguntas distintas.

## Definición de done

- [ ] Los cinco casos de `mix test test/candil/router/` en verde
- [ ] `./candil router test` imprime modelo, score y alternativas
- [ ] `./candil router stats` imprime p50, p95 y errores
- [ ] El property test corre de verdad, no es un ejemplo con nombre de test
- [ ] Los ocho gates verdes
- [ ] El número de tests no ha bajado de 702
- [ ] `CHANGELOG.md` y `HANDOFF.md` al día
- [ ] PR contra `4.0`, CI verde
- [ ] **cerrado a `main`**: sync `main` → `4.0` y PR `4.0` → `main`
- [ ] Tag `candil-4.0.0-beta.1`

## La rama

```
git fetch origin
# antes: sincroniza, para que 4.0 no se vaya atrasando de main
# git checkout 4.0 && git merge origin/main && git push origin 4.0
git checkout -b 4.0-f7-router origin/4.0
```
