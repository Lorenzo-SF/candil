# Fase 9 — MCP

> Estado: **pendiente**. Depende de la 8. Carril F.
> Original: `../original/candil-4.0-final.md` §21 y la Fase 9.
> Effort: 4 d.

## Qué es

Servidor **y** cliente MCP, en la revisión `2025-11-25`. Servidor: Candil
expone herramientas. Cliente: Candil llama a otros servidores y expone lo que
devuelven como herramientas propias.

## Por qué aquí

Después del gateway, porque el MCP se enchufa como un endpoint más. No antes:
sin gateway, cada consumidor necesita su propio cliente MCP.

## Dónde

| Qué | Dónde |
|---|---|
| Módulos | `lib/candil/mcp.ex` y `lib/candil/mcp/**` |
| Tests | `test/candil/mcp/**` |
| Ya existe | `MCP`, `MCP.Protocol` — solo el **protocolo** está escrito |
| **Hay que crearlos** | `MCP.Server`, `MCP.Client`, `MCP.Transport`, `MCP.Builtin` y `MCP.Builtin.Tools` — **no existen todavía**. Es la fase que más código nuevo tiene de las que quedan |

**Carril F.** No toques `gateway/**`, `router/**` ni `rag/**`.

## Qué hay que hacer

### La revisión, que es donde está el riesgo

La revisión de protocolo se compara como **cadena**. El fallo concreto que hay
que evitar: comparar contra la **tupla de la revisión**, que hace que un cliente
que manda `"2025-06-18"` no coincida nunca con la revisión del servidor y acabe
en bucle de `initialize`.

- `initialize` con **cada** revisión soportada → responde la del **servidor**.
- `initialize` con una revisión **no soportada** → responde **la del servidor**,
  no un error. Es lo que dice el spec.
- **HTTP sin cabecera** `MCP-Protocol-Version` → asume `2025-03-26` y funciona.
- **HTTP con versión inválida** → `400`. Distinguir "no la mandaste" de "la
  mandaste mal" es obligatorio: uno tiene un valor por defecto, el otro es un
  error del cliente.

### Handlers con nombre

`MCP.Builtin` lleva `tools/list` y `tools/call`. Cada tool tiene su
`Meta.handler`: un `model`, no un string. El patrón es `dispatch/2` con
`:"Elixir.Candil.MCP.Builtin.Tools"`, y el campo `name` es `"candil_status"`.

### Tools para MCP

`candil_models` y `candil_doctor`. Un servidor MCP cuyo valor es enumerar
modelos y decir si el sistema está sano es útil **precisamente** porque quien
lo consulta es un LLM.

## Cómo se comprueba

```bash
mix test test/candil/mcp/
#   - initialize con cada revisión soportada
#   - initialize con una no soportada → responde la del servidor
#   - HTTP sin MCP-Protocol-Version → asume 2025-03-26 y funciona
#   - HTTP con versión inválida → 400
#   - tools/list devuelve las tools registradas, con Meta.handler
#   - un cliente real (mcp inspector) habla con el servidor
```

## Por qué NO

- **No implementar el protocolo entero.** Solo lo que Candil necesita hablar:
  `initialize`, `tools/list`, `tools/call`. Un MCP completo son semanas y no se
  va a usar entero.
- **No meter MCP en la CLI principal.** Es un subcomando.
- **No usar `String.to_atom/1` sobre nombres de tool que vienen por la red.**
  Ya está resuelto: la 9 es la razón de ser del **atom factory** y del
  `Candil.AtomTable`. Ese módulo existe por esto.

## Definición de done

- [ ] `mix test test/candil/mcp/` en verde, los seis casos
- [ ] Un cliente real habla con el servidor (inspector o un cliente MCP de verdad)
- [ ] `tools/list` devuelve las tools con su `Meta.handler`
- [ ] Los ocho gates verdes
- [ ] El número de tests no ha bajado de 702
- [ ] `CHANGELOG.md` y `HANDOFF.md` al día
- [ ] PR contra `4.0`, CI verde

## La rama

```
git fetch origin
git checkout -b 4.0-f9-mcp origin/4.0
```

## Nota operativa

⚠ **Esta fase con 4 equipos no cabe en 30 minutos.** Ya se intentó y el plan no
entregó. Si la haces con agentes, trocéala en slices de menos de media hora con
worktrees independientes, o hazla secuencial. El prompt largo de la 9, la 5 y
la 10 está en `PROMPT-VENTANA-PARALELA.md`, junto con el plan — pero la 5 ya
está hecha y este documento la sustituye.
