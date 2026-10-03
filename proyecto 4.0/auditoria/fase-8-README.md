# Fase 8 — Gateway

> Estado: **pendiente**. Depende de la 7. Carril E.
> Original: `candil-4.0-final.md` §20 y la Fase 8.
> Effort: 5 d.
>
> **Nivel de razonamiento de la fase: `high` — sube a `max` en §3.4 y `xhigh`
> en §3.5.**
> Razón: el `model` de la petición viene de la red, y la normalización entre
> APIs es donde se pierden los casos raros.

---

## 1. Antes de empezar

- [ ] **La fase 7 está mergeada en `main`.** El gateway enruta: sin router tiene
      que adivinar el modelo, y eso no es el diseño. Si la 7 no está, **para**.
- [ ] **Anota el número real de tests en `main`** en `HANDOFF.md`. Las
      referencias "702" y "687 + 26" de aquí **estaban mal**: la base real
      medida es **705 + 26 doctests**, 0 fallos, 66.2 % (2026-10-03, `7fc0920`).
      Mídela al abrir la rama; este número envejece como los otros.

---

## 2. Qué es

Un endpoint **OpenAI-compatible** que enruta. La gente ya tiene clientes OpenAI
en su configuración; si Candil habla el mismo idioma, no hay que tocar nada del
otro lado para adoptarlo.

Es la fase que convierte Candil en algo que los consumidores **usan de verdad**,
no en una librería que hay que integrar.

---

## 3. Dónde

| Qué | Dónde |
|---|---|
| Módulos | `lib/candil/gateway.ex` y `lib/candil/gateway/**` |
| Tests | `test/candil/gateway*_test.exs` |
| Ya existe | `Gateway`, `Gateway.Endpoint`, `Gateway.Auth` — esqueletos de la −1 |
| **Hay que crearlos** | `Gateway.Metrics`, `Gateway.RouteCache`, `Gateway.RouteCacheProc` — **no existen todavía** |

**Carril E.** No toques `router/**`, `mcp/**` ni `rag/**`.

---

## 4. Qué hay que hacer

### 3.1 Los cinco endpoints · `medium`

`/v1/chat/completions`, `/v1/embeddings`, `/health`, `/metrics`, y
`/c/:consumer/v1/...` para forzar el consumer.

### 3.2 `model: "auto"` · `medium`

Arranca el modelo si hace falta, enruta y responde. Es la forma en que se usa por
defecto. El arranque es el de la fase 4, ya hecho.

### 3.3 `RouteCache` con su propio proc · `medium`

**No está en `Candil.Router.Cache`**: el router cachea *decisiones*, el gateway
cachea *respuestas*. Son cosas distintas. Un `Agent` con límite de entradas está
bien para el segundo.

El error fácil aquí es reutilizar `Router.Cache` "porque ya existe". Cachear una
respuesta de chat en un mapa sin TTL es una fuga de memoria con aspecto de
optimización.

### 3.4 Auth, y el `model` de la red · `max`

- `none` **solo** en loopback. Cualquier otro modo exige token.
- Nunca `auth: none` en `0.0.0.0`. Loopback o token, y en ese orden.
- El gateway recibe `model` de la red, y la **regla dura 7** prohíbe
  `String.to_atom/1` con input externo. `String.to_existing_atom/1`, y si falla
  `{:error, :unknown_model}`.

Es `max` porque es el único sitio de todo el plan donde un input no confiable
cruza un límite de seguridad, y ya costó dos veces en este repo. La tabla de
átomos del BEAM no crece, pero el modo de fallo (un `:erlang.garbage_collect` de
la tabla) es un crash del nodo entero.

### 3.5 El `normalizer` · `xhigh`

Viene de ElPaso, y es donde se pierden los casos raros: campos que un backend
acepta y otro no, streaming, tool calls, `reasoning_content`, `null` vs. ausente.

`xhigh` no por el volumen sino por la asimetría del fallo: una request que no se
normaliza bien **funciona con tu cliente y falla con el de otro**.

### 3.6 Métricas · `medium`

`telemetry` de fondo, **registradas en el supervisor de `telemetry`**, no en el
de la aplicación. Dos registros en el sitio equivocado = doble conteo o pérdida.

### 3.7 Tests sin salir a internet · `medium`

`:none` y `:pass` a `:none` de Candil, no de Finch. Si no, los tests fallan por
un socket a internet, no por la lógica. En un sandbox sin red, eso es la
diferencia entre un fallo real y uno falso.

---

## 5. Capa 1 — Los ocho gates

```bash
mix format --check-formatted
mix compile --force --warnings-as-errors
mix credo --strict --format=oneline
mix test --cover
mix dialyzer
mix docs --warnings-as-errors
mix hex.audit
mix deps.unlock --check-unused
```

Todos en verde. **La base se mira en `main` al abrir la rama.** Si el número de
tests baja, **para**.

---

## 6. Capa 2 — Qué tiene que pasar al ejecutar

```bash
mix test test/candil/gateway_test.exs
```

| Qué se prueba | Qué tiene que ocurrir | Qué NO puede ocurrir |
|---|---|---|
| `model` inválido de la red | `{:error, :unknown_model}` o 400 con mensaje | un crash por `String.to_atom/1`, o un `ArgumentError` crudo |
| `model` válido | enruta y responde | que se cree un átomo nuevo por request |
| `auth: none` en `0.0.0.0` | **rechazado al arrancar** | que arranque y acepte peticiones sin token |
| `auth: none` en loopback | arranca, y lo dice en la línea de arranque | que arranque en silencio |
| `/c/:consumer/v1/...` | el consumer llega al router y a `Cost` | que se ignore y acabe en el `default` |
| streaming | chunks progresivos | un chunk único con todo el body |
| tests sin red | pasan con el pool en `:none` | que fallen por `econnrefused` |

**El caso de los átomos es el que hay que probar dos veces:** con un `model` que
existe y con uno que no. Solo el segundo detecta el `to_atom`.

---

## 7. Capa 3 — Revisión manual del código

- [ ] `grep -rn "String.to_atom" lib/candil/gateway/` → **0 resultados**.
      `to_existing_atom` sí, y su `{:error, :}` manejado.
- [ ] ¿El `model` de la red se resuelve a átomo en algún punto, o se compara
      como string y se convierte al final?
- [ ] ¿`auth: none` con `host` distinto de loopback **falla al arrancar**, y no
      avisa por log y sigue?
- [ ] ¿`RouteCache` es un módulo **distinto** de `Router.Cache`, con su propio
      TTL? No es un alias.
- [ ] ¿Las métricas se registran **una** vez? Busca `attach` en `gateway/**` y
      cuenta.
- [ ] ¿El `normalizer` trata `nil` y ausente como cosas distintas? En JSON no lo
      son, y un `nil` explícito llega como `null`.
- [ ] ¿Hay billing propio? El coste sale de `Cost.track/5`. Doble conteo.

---

## 8. Capa 4 — La prueba funcional

### El criterio de verdad: un cliente OpenAI de PyPI, no un test nuestro

```python
from openai import OpenAI
c = OpenAI(base_url="http://127.0.0.1:7777/v1", api_key="not-needed-in-none-mode")
print(c.chat.completions.create(model="auto",
      messages=[{"role":"user","content":"hola"}]).choices[0].message.content)
```

> Un test nuestro que dice que responde **no demuestra** que un cliente OpenAI
> real lo entienda, y ese cliente es el consumidor.

**Qué tiene que ocurrir:** imprime una cadena de texto, sin excepción.

**Qué NO tiene que ocurrir:**

- ❌ un `AttributeError` por un campo que el SDK espera y no está
- ❌ un 404 porque la ruta real es `/v1/chat/completions` y pusiste `/v1/chat`
- ❌ que funcione con `curl` y falle con el SDK: el SDK manda cabeceras que curl
  no manda

### Los endpoints

```bash
$ ./candil gateway start
✓ gateway en http://127.0.0.1:7777 (auth: none, solo loopback)

$ curl -X POST localhost:7777/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{"model":"auto","messages":[{"role":"user","content":"hola"}]}'
# → arranca coder si hace falta, enruta, responde OpenAI-compatible

$ curl -X POST localhost:7777/c/posadero/v1/embeddings \
    -d '{"model":"embed","input":["uno","dos"]}'

$ curl localhost:7777/metrics | head -5
$ curl localhost:7777/health
```

**Qué NO tiene que ocurrir:**

- ❌ `/health` que responde 200 con el router caído. `/health` que no mira el
  router es un health check que miente.
- ❌ que `model: "auto"` devuelva 400 porque no hay modelos
- ❌ que el gateway escuche en `0.0.0.0` sin token

### La prueba de seguridad, que no estaba en el documento

```bash
# un `model` inventado desde la red, no desde el código
curl -X POST localhost:7777/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"no-existe-este-modelo","messages":[{"role":"user","content":"hola"}]}'
```

Tiene que devolver `400` con un mensaje que nombre los modelos válidos. **No** un
500, **no** un crash, **no** un hang. Y el proceso tiene que seguir contestando
después:

```bash
# el gateway sigue vivo
curl localhost:7777/health
```

Si ese segundo `curl` no responde, el `to_atom` te tumbó el nodo.

---

## 9. Por qué NO

- **No capa de billing:** el coste ya sale de `Cost.track/5`. Doble conteo.
- **No una API propia.** Si habla otro idioma, cada consumidor escribe un cliente.
- **No `auth: none` en `0.0.0.0`.** Nunca. Loopback o token, y en ese orden.

---

## 10. Lo que NO vas a hacer

- No toques `router/**`, `context/**`, `mcp/**`, `rag/**`.
- No toques ficheros del carril A: `model.ex`, `engine.ex`, `engine_pool.ex`,
  `build.ex`, `source.ex`, `store.ex`, `config/**`, `inference/**`, `engine/**`.
- No toques `mix.exs`. `groups_for_modules` se pide en el PR.
- No uses `String.to_atom/1` con nada que venga de la red. **Nunca.**
- No reimplementes el router dentro del gateway. El gateway enruta; quién y cómo,
  es del router.
- No hagas `git push --force`.

---

## 11. Definición de done

- [ ] `mix test test/candil/gateway_test.exs` en verde
- [ ] Los cinco endpoints responden lo que dice el diseño
- [ ] **El cliente OpenAI de PyPI imprime una respuesta** ← el criterio
- [ ] `/health` y `/metrics` responden
- [ ] Un `model` inexistente da 400 y **el gateway sigue vivo** después
- [ ] `auth: none` en `0.0.0.0` falla al arrancar
- [ ] Los ocho gates verdes
- [ ] El número de tests no ha bajado de la base real anotada
- [ ] `CHANGELOG.md` y `HANDOFF.md` al día
- [ ] PR contra `main`, CI verde
- [ ] Tag `candil-4.0.0-beta.2`

---


## 12. Cómo se ejecuta esta fase

**Una sesión principal, secuencial, en `mcode`.** El nivel se cambia **por
sub-tarea** con `/model` (verificado: `/model` cambia modelo **y** effort, y
`/status` muestra el par). El modelo no puede cambiar su propio effort a mitad de
respuesta: el ajuste es **entre turnos**, y por eso la unidad es la sub-tarea.

### El ciclo

```bash
# 1. en main, actualizado
git checkout main && git fetch origin && git pull --ff-only origin main

# 2. rama de la fase  (CON GUION, nunca barra)
git checkout -b f8-gateway

# 3. implementar la fase COMPLETA, sub-tarea por sub-tarea,
#    cambiando el nivel con /model en cada frontera

# 4. verificar las 4 capas (abajo)

# 5. publicar
git push -u origin f8-gateway

# 6. PR contra main. MIRA EL CI antes de pedir el merge.

# 7. merge a main y cerrar el ciclo:
#    HANDOFF.md §2 con números MEDIDOS · CHANGELOG.md · el tag
```

Un worktree por sesión, un `_build` por carril.

### El nivel, sub-tarea por sub-tarea

| Sub-tarea | Nivel | Verificación |
|---|---|---|
| 3.1 Los cinco endpoints | `medium` | L3: `gateway_test.exs` |
| 3.2 `model: "auto"` arranca y enruta | `medium` | L4: arranca el modelo si hace falta |
| 3.3 `RouteCache` con su propio proc | `medium` | L3: NO es `Router.Cache`; TTL propio |
| 3.4 Auth + `model` de la red | `max` | L4: model inexistente → 400 y el gateway sigue vivo |
| 3.5 `Normalizer` de ElPaso | `xhigh` | L3: `nil` vs ausente; streaming; `reasoning_content` |
| D5 `reasoning_effort` traducido por modelo | `high` | L4: modelo sin soporte → cabecera `X-Candil-Reasoning-Ignored` |
| Revisión de la fase (sesión aparte) | `max` | L4: **el cliente OpenAI de PyPI imprime** |

**Y al final, siempre:** una sesión de revisión aparte, a `max`, leyendo el PR
**sin el diff del autor**. Es la única tarea del plan donde el nivel base es el
máximo, porque es la única donde el agente no puede estar calibrado por haber
escrito el módulo.

### Las 4 capas, en cada sub-tarea

| Capa | Qué | Obligatoria |
|---|---|---|
| **L1** | `mix format --check-formatted` + `mix compile --force --warnings-as-errors` | siempre |
| **L2** | `mix credo --strict` + `mix dialyzer` | si toca código compartido |
| **L3** | `CANDIL_DATA_DIR=$(mktemp -d) mix test <ruta>/` con el caso nombrado | siempre |
| **L4** | un comando con salida observable, **y qué NO puede ocurrir** | si es visible para el usuario |

La **aserción negativa** es la que importa: un criterio que solo dice "responde"
pasa con un `[]` de respuesta.

### Si se bloqueas

**PARA.** No improvises una decisión de diseño: están todas escritas. Anótala en
`deliverable.md` y sigue con la siguiente sub-tarea que no dependa de eso.

**Y si un criterio no se ejecutó porque el entorno no lo permite, dilo.** Escribe
*"criterio ejecutado: unitario, no integración"*. Un `deliverable.md` que dice
"criterio ejecutado" cuando se ejecutó la mitad es una mentira, y la siguiente
sesión la da por buena.
