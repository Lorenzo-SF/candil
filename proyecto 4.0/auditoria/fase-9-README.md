# Fase 9 — MCP

> Estado: **BLOQUEADA — pendiente de decisión.** Depende de la 8. Carril F.
> Original: `candil-4.0-final.md` §21 y la Fase 9.
> Effort: 4 d.
>
> **Nivel de razonamiento de la fase: `xhigh` — sube a `max` en §3.1.**
> Razón: la revisión del protocolo es el riesgo de la fase, y hay que leer la
> spec, no deducirla de la memoria.

---

## 🛑 0. BLOQUEANTE — lee esto antes de nada

**Esta fase no debería empezar hasta que decidas qué revisión del protocolo
implementa Candil.**

Verificado hoy contra `modelcontextprotocol.io/specification/versioning`:

| Revisión | Estado | Handshake `initialize` |
|---|---|---|
| `2024-11-05` | Legacy | sí |
| `2025-03-26` | Legacy | sí |
| `2025-06-18` | Legacy | sí |
| `2025-11-25` | **Legacy** (handshake-based) | sí |
| **`2026-07-28`** | **Current** | **eliminado** |

El documento de esta fase dice, en tres sitios, que la revisión es `2025-11-25`
y que el handshake `initialize` es **obligatorio**. En la revisión `Current`
(`2026-07-28`) el handshake está **eliminado**: MCP es stateless, cada request
lleva la versión en `_meta` (`io.modelcontextprotocol/protocolVersion`), hay un
RPC nuevo `server/discover`, y los fallos de versión devuelven
`UnsupportedProtocolVersionError`.

**Opciones, y la recomendación:**

- **Opción A — `2026-07-28` (Current).** ✅ **Recomendada.** Es la correcta hoy y
  lo que un cliente moderno espera. Coste: **un día más**, y reescribir el §3.1
  entero. Ahorro: no tirar la fase cuando se migre.
- **Opción B — `2025-11-25` (Legacy), tal como está escrito.** Funciona con
  clientes que aún usan handshake. Es trabajo que se tira en la migración.
- **Opción C — `2026-07-28` con fallback de `2025-11-25`**, que es lo que hacen los
  SDK oficiales. Más trabajo, y el fallback es justo la parte que nadie usa.

**Con la A**, `@supported_versions` lleva las cinco revisiones y `server/discover`
está implementado. **Con la B**, este documento vale tal cual.

**Lo que sí está bien y no hay que tocar, porque sigue siendo cierto a día de
hoy:**

- El batching JSON-RPC se eliminó en `2025-06-18` (PR #416, confirmado en el
  changelog oficial). Un array de requests es un **error**, no algo que se
  procese request a request.
- El header `MCP-Protocol-Version` pasó a ser obligatorio en `2025-06-18`
  (PR #548). Sin él se asume `2025-03-26` por retrocompatibilidad.

---

## 1. Qué es

Servidor **y** cliente MCP. Servidor: Candil expone herramientas. Cliente:
Candil llama a otros servidores y expone lo que devuelven como herramientas
propias.

Después del gateway, porque el MCP se enchufa como un endpoint más. No antes:
sin gateway, cada consumidor necesita su propio cliente MCP.

---

## 2. Dónde

| Qué | Dónde |
|---|---|
| Módulos | `lib/candil/mcp.ex` y `lib/candil/mcp/**` |
| Tests | `test/candil/mcp*_test.exs` |
| Ya existe | `MCP`, `MCP.Protocol` — solo el **protocolo** está escrito |
| **Hay que crearlos** | `MCP.Server`, `MCP.Client`, `MCP.Transport`, `MCP.Builtin`, `MCP.Builtin.Tools` — **no existen todavía**. Es la fase con más código nuevo de las que quedan |

**Carril F.** No toques `gateway/**`, `router/**` ni `rag/**`.

---

## 3. Qué hay que hacer

### 3.1 La revisión del protocolo · `max` · **BLOQUEANTE**

**Lee la spec antes de escribir código.** No la deduzcas: la fase ya lleva dos
generaciones de retraso porque alguien lo leyó de memoria.

Lo que hay que cumplir, con la revisión elegida:

- `initialize` con **cada** revisión soportada → responde la del **servidor**
- `initialize` con una revisión **no soportada** → responde **la del servidor**,
  no un error (esto es lo que dice el spec en la era del handshake; **cambia en
  `2026-07-28`**)
- HTTP **sin** cabecera `MCP-Protocol-Version` → asume `2025-03-26` y funciona
- HTTP **con** versión inválida → `400`. Distinguir "no la mandaste" de "la mandaste
  mal" es obligatorio: uno tiene un valor por defecto, el otro es un error del
  cliente

**Con la opción A (`2026-07-28`)** en lugar de lo anterior:

- No hay `initialize`: cada request lleva `io.modelcontextprotocol/protocolVersion`
  en `_meta`
- Hay `server/discover`, que los servidores **deben** implementar
- Un desajuste de versión devuelve `UnsupportedProtocolVersionError`

**El fallo concreto que hay que evitar:** comparar contra **la tupla** de la
revisión en vez de contra la **cadena**. Un cliente que manda `"2025-06-18"` no
coincide nunca y acaba en bucle de `initialize`.

### 3.2 Handlers con nombre · `medium`

`MCP.Builtin` lleva `tools/list` y `tools/call`. Cada tool tiene su
`Meta.handler`: un **modelo**, no un string. El patrón es `dispatch/2` con
`:"Elixir.Candil.MCP.Builtin.Tools"`, y el campo `name` es `"candil_status"`.

Que sea un modelo y no un string no es estilo: es lo que permite que dialyzer
compruebe que el módulo existe.

### 3.3 Un tool que lanza NO tumba el servidor · `high`

Es el test más importante de la fase y el más fácil de perder. Un tool que lanza
una excepción tiene que producir **error -32603** en la respuesta de esa petición,
y el servidor sigue escuchando.

Si el tool tumba el proceso, un cliente con una tool rocosa se queda sin servidor
y no sabe por qué.

### 3.4 Los dos transports · `medium`

| Transport | Para | Notas |
|---|---|---|
| `stdio` | que opencode lo lance como subprocess | el shim por defecto |
| `http` | compartido y clientes remotos | header de versión obligatorio |

### 3.5 Tools para MCP · `medium`

`candil_models` y `candil_doctor`. Un servidor MCP cuyo valor es enumerar modelos
y decir si el sistema está sano es útil **precisamente** porque quien lo consulta
es un LLM.

---

## 4. Capa 1 — Los ocho gates

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

Todos en verde. **La base se mira en `main` al abrir la rama.** Las referencias
"702" y "687 + 26" estaban mal: la base real medida es **705 + 26 doctests**, 0 fallos, 66.2 % (2026-10-03, `7fc0920`).
Mídela al abrir la rama; este número envejece como los otros.

Un stub que hace `raise` es `none()` para dialyzer. Si escribes uno, devuelve
`{:error, %Candil.Error{reason: :not_implemented}}`, que cumple su `@spec`.

---

## 5. Capa 2 — Qué tiene que pasar al ejecutar

```bash
mix test test/candil/mcp_protocol_test.exs
```

| Test | Qué tiene que ocurrir | Qué NO puede ocurrir |
|---|---|---|
| `initialize` con cada revisión soportada | responde la del **servidor** | que responda la del cliente |
| `initialize` con una no soportada | responde la del **servidor** | un error, o un bucle |
| HTTP **sin** `MCP-Protocol-Version` | asume `2025-03-26` y funciona | un 400 |
| HTTP **con** versión inválida | `400` | que lo trate como "no mandada" |
| batching (array de requests) | **error** | que lo procese request a request |
| `tools/list` | las tools registradas, con `Meta.handler` | strings en vez de módulos |
| un tool que lanza | `-32603` en esa respuesta, **el servidor sigue** | que muera el proceso |
| un cliente real | el inspector habla con el servidor | que solo funcione el test propio |

**El caso del batching es el que más se cuela**, porque "soportar más formatos"
parece robustez. Aquí es un error de protocolo y un array tiene que rechazarse.

---

## 6. Capa 3 — Revisión manual del código

- [ ] ¿La revisión se compara como **cadena** (`@supported_versions ~w[...]`) y
      no como tupla? Busca el `==` y mira los dos lados.
- [ ] ¿Hay un solo sitio con la lista de revisiones? Si aparece en dos ficheros,
      van a divergir.
- [ ] ¿El array de requests se rechaza con un **parse error**, o entra al
      dispatcher y falla más tarde?
- [ ] ¿Un tool que lanza produce `-32603` con el mensaje, y el GenServer sigue
      vivo? Busca un `try/rescue` alrededor del dispatch, no dentro.
- [ ] `grep -rn "String.to_atom" lib/candil/mcp/` → **0**. Los nombres de tool
      vienen de la red.
- [ ] ¿`Meta.handler` es un **módulo compilado**, no un string? Si es un string,
      dialyzer no comprueba nada.
- [ ] ¿El `MCP.Builtin` expone más que `tools/list` y `tools/call`? El README
      dice que no se implementa el protocolo entero.

---

## 7. Capa 4 — La prueba funcional

```bash
# stdio, el shim por defecto
echo '{"jsonrpc":"2.0","id":1,"method":"initialize",
       "params":{"protocolVersion":"2025-11-25","capabilities":{},
                 "clientInfo":{"name":"test","version":"1"}}}' \
  | ./candil mcp serve --transport stdio

# http
./candil mcp serve --transport http --port 7778 &
curl -X POST localhost:7778/mcp -H 'MCP-Protocol-Version: 2025-11-25' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
```

**Qué tiene que ocurrir:** un JSON-RPC válido con `result`, y el servidor queda
escuchando después.

**Qué NO tiene que ocurrir:**

- ❌ que un cliente real (inspector) no consiga conectar. Es el criterio, y no
  está en los tests: el test propio puede hablar un dialecto y el inspector otro.
- ❌ que `tools/list` devuelva `handler` como string
- ❌ que el proceso termine tras el `echo` (stdio debe cerrarse limpio al EOF,
  pero el proceso HTTP debe seguir)

**La prueba de la tool que revienta:**

```bash
# registrar una tool que lance, y llamarla
# → respuesta con error -32603
# → y LUEGO:
curl -X POST localhost:7778/mcp -H 'MCP-Protocol-Version: 2025-11-25' \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/list"}'
```

El segundo `curl` tiene que responder. Si no, la tool rocosa se llevó el
servidor, y eso es el fallo exacto que la fase previene.

---

## 8. Por qué NO

- **No implementar el protocolo entero.** Solo lo que Candil necesita hablar:
  `initialize`, `tools/list`, `tools/call`. Un MCP completo son semanas y no se
  va a usar entero.
- **No meter MCP en la CLI principal.** Es un subcomando.
- **No usar `String.to_atom/1` sobre nombres de tool que vienen por la red.** Ya
  está resuelto: la 9 es la razón de ser del atom factory y del
  `Candil.AtomTable`. Ese módulo existe por esto.

---

## 9. Lo que NO vas a hacer

- No toques `doctor.ex`, `rag.ex` ni sus tests: son las fases 5 y 10.
- No toques ficheros del carril A: `model.ex`, `engine.ex`, `engine_pool.ex`,
  `build.ex`, `source.ex`, `store.ex`, `config/**`, `detector.ex`, `engine/**`.
- No toques `tool.ex`. Es la dependencia de la que cuelga esta fase.
- No toques `mix.exs`. `groups_for_modules` se pide en el PR.
- **No añadas batching.** Se eliminó del protocolo en `2025-06-18`.
- No hagas `git push --force`.

---

## 10. Definición de done

- [ ] **La revisión del protocolo está decidida y escrita en `HANDOFF.md`**
- [ ] `mix test test/candil/mcp_protocol_test.exs` en verde, los seis casos
- [ ] Un cliente real habla con el servidor (inspector o un cliente MCP de verdad)
- [ ] `tools/list` devuelve las tools con su `Meta.handler`
- [ ] Una tool que lanza da `-32603` y **el servidor sigue respondiendo**
- [ ] Los ocho gates verdes
- [ ] El número de tests no ha bajado de la base real anotada
- [ ] `CHANGELOG.md` y `HANDOFF.md` al día
- [ ] PR contra `main`, CI verde
- [ ] Tag `candil-4.0.0-rc.1`

---


## 11. Nota operativa

⚠ **Esta fase con 4 equipos no cabe en 30 minutos.** Ya se intentó y el plan no
entregó. Si la haces con agentes, trocéala en slices de menos de media hora con
worktrees independientes, o hazla secuencial.

El prompt largo de la 9, la 5 y la 10 está en `PROMPT-VENTANA-PARALELA.md`. La
**5 ya está hecha** y su README la sustituye. El de la 9 **también** — y ahora
con el bloqueante de la revisión, que no estaba.


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
git checkout -b f9-mcp

# 3. implementar la fase COMPLETA, sub-tarea por sub-tarea,
#    cambiando el nivel con /model en cada frontera

# 4. verificar las 4 capas (abajo)

# 5. publicar
git push -u origin f9-mcp

# 6. PR contra main. MIRA EL CI antes de pedir el merge.

# 7. merge a main y cerrar el ciclo:
#    HANDOFF.md §2 con números MEDIDOS · CHANGELOG.md · el tag
```

Un worktree por sesión, un `_build` por carril.

### El nivel, sub-tarea por sub-tarea

| Sub-tarea | Nivel | Verificación |
|---|---|---|
| Puerta: decidir la revisión del protocolo (A1) | `PARA` | Decisión del dueño. Sin esto no arranca la fase |
| 3.1 La revisión del protocolo | `max` | L3: cadena, no tupla; batching → error |
| 3.2 Handlers con `Meta.handler` (módulo) | `medium` | L3: dialyzer comprueba el módulo |
| 3.3 Un tool que lanza no tumba el servidor | `high` | L4: `-32603` y el servidor sigue |
| 3.4 Los dos transports | `medium` | L4: stdio y http responden |
| 3.5 Tools `candil_models` y `candil_doctor` | `medium` | L3: `tools/list` las devuelve |
| Revisión de la fase (sesión aparte) | `max` | L4: el inspector real habla con el servidor |

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
