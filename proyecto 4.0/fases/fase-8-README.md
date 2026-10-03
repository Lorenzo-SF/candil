# Fase 8 — Gateway

> Estado: **pendiente**. Depende de la 7. Carril E.
> Original: `../original/candil-4.0-final.md` §20 y la Fase 8 (~línea 2310).

## Qué es

Un endpoint **OpenAI-compatible** que enruta. La gente ya tiene clientes
OpenAI en su configuración; si Candil habla el mismo idioma, no hay que tocar
nada del otro lado para adoptarlo.

## Por qué aquí

Es la fase que convierte Candil en algo que los consumidores **usan de verdad**,
no en una librería que hay que integrar. Depende de la 7 porque enruta: sin
router, el gateway tiene que adivinar el modelo.

## Dónde

| Qué | Dónde |
|---|---|
| Módulos | `lib/candil/gateway.ex` y `lib/candil/gateway/**` |
| Tests | `test/candil/gateway/**` |
| Ya existe | `Gateway`, `Gateway.Endpoint`, `Gateway.Auth` — esqueletos de la −1 |
| **Hay que crearlos** | `Gateway.Metrics`, `Gateway.RouteCache`, `Gateway.RouteCacheProc` — **no existen todavía** |

**Carril E.** No toques `router/**`, `mcp/**` ni `rag/**`.

## Qué hay que hacer

1. **Endpoints**: `/v1/chat/completions`, `/v1/embeddings`, `/health`,
   `/metrics`, y `/c/:consumer/v1/...` para forzar el consumer.
2. **`model: "auto"`** arranca el modelo si hace falta, enruta y responde. Es
   la forma en que se usa por defecto.
3. **`RouteCache` con su propio proc, GenServer o Agent.** **No está en el
   `Candil.Router.Cache`**: el router cachea *decisiones*, el gateway cachea
   *respuestas*. Cool. Un `Agent` con límite de entradas está bien para el
   segundo.
4. **Auth**: `none` solo en loopback. Cualquier otro modo exige token.
5. **`:none` y `:pass` a `:none` de Candil, no de Finch** — si no, los tests
   fallan por un socket a internet, no por la lógica.
6. **Métricas** con `telemetry` de fondo, **registradas en el `telemetry`
   supervisor**, no en el de la aplicación.

## Cómo se comprueba

```bash
mix test test/candil/gateway/

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

## Y el criterio de verdad

**Un cliente OpenAI real, de PyPI, no un test nuestro:**

```python
from openai import OpenAI
c = OpenAI(base_url="http://127.0.0.1:7777/v1", api_key="not-needed-in-none-mode")
print(c.chat.completions.create(model="auto",
      messages=[{"role":"user","content":"hola"}]).choices[0].message.content)
```

Si eso imprime algo, el gateway es un gateway. Un test nuestro que dice que
responde no demuestra que un cliente OpenAI real lo entienda, y ese cliente es
el consumidor.

## Por qué NO

- **No开支 de billing: el coste ya sale de `Cost.track/5`.** Doble conteo.
- **No una API propia.** Si habla otro idioma, cada consumidor escribe un
  cliente.
- **No `auth: none` en `0.0.0.0`.** Nunca. Loopback o token, y en ese orden.

## Definición de done

- [ ] `mix test test/candil/gateway/` en verde
- [ ] Los cinco endpoints responden lo que dice el diseño
- [ ] El cliente OpenAI de PyPI imprime una respuesta (criterio)
- [ ] `/health` y `/metrics` responden
- [ ] Los ocho gates verdes
- [ ] El número de tests no ha bajado de 702
- [ ] `CHANGELOG.md` y `HANDOFF.md` al día
- [ ] PR contra `4.0`, CI verde
- [ ] **cerrado a `main`**: sync `main` → `4.0` y PR `4.0` → `main`
- [ ] Tag `candil-4.0.0-beta.2`

## La rama

```
git fetch origin
# antes: sincroniza, para que 4.0 no se vaya atrasando de main
# git checkout 4.0 && git merge origin/main && git push origin 4.0
git checkout -b 4.0-f8-gateway origin/4.0
```
