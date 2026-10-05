# BLOQUEO · F6 §3.6 — `Candil.chat_with_context/4`

> **Rama**: `f6-context` · **Fecha**: 2026-10-03 · **Estado**: escrito, verificado
> en runtime, **fuera del árbol** porque no pasa el gate L2.
>
> El código no está perdido: está en `3.6-chat_with_context.patch`, en esta misma
> carpeta. `git apply 3.6-chat_with_context.patch` lo devuelve cuando el fondo
> esté resuelto.

## Qué es

La sub-tarea 3.6 del README de la F6: el facade público que cablea
`{consumer, session_id}` con el modelo. Es lo que D8 nombra como sustituto de
`Candil.Conversation`, y por eso el módulo deprecado **apunta a él**.

El comportamiento se verificó en vivo, no supuesto:

```elixir
Candil.chat_with_context(:coder, "s1", [%{role: "user", content: "hola"}], consumer: :posadero)
#=> {:error, %Candil.Error{reason: :model_not_found, context: %{model_alias: :coder}}}
```

## Por qué no está en el árbol

`mix dialyzer` falla con dos avisos, y los dos son de esta función:

```
lib/candil/context.ex:140:16:pattern_match
The pattern can never match the type.
Pattern:  {:ok, _response}
Type:     {:error, %Candil.Error{...}}

lib/candil/context.ex:161:8:unused_fun
Function content_of/1 will never be called.
```

Es decir: dialyzer concluye que la llamada al modelo **nunca** devuelve `{:ok, _}`,
así que la rama de éxito —y con ella el registro de la respuesta del asistente—
le parece código muerto.

## Lo que se ha descartado, midiendo

| Sospecha | Resultado |
|---|---|
| El `@spec` de `Context.chat/4` es demasiado estrecho | No. El aviso no menciona el contrato, solo el tipo del valor. |
| `Candil.Inference.Chat` sin specs | **Arreglado** (2 specs añadidas, son correctas). No era la causa. |
| `Builder.build/3` devolviendo `[map()]` en vez de `[message()]` | **Arreglado** (spec honesta). No era la causa. |
| `Candil.chat/3` sin `@spec` | **Arreglado**. No era la causa. |
| Ciclo `Candil` ↔ `Candil.Context` | **Roto**, llamando a `Inference` directamente. No era la causa. |
| `Candil.HTTP.post_json/4` solo devuelve error | Descartado con sonda: dialyzer acepta `{:ok, _}`. |
| `Engine.base_url/1` siempre `nil` | Descartado con sonda: dialyzer acepta `binary()`. |
| `Store.get_model/1` nunca `{:ok, _}` | Descartado: su spec y su cuerpo lo permiten. |

**Lo que queda sin localizar**: por qué el *success typing* que dialyzer infiere
para la cadena `Inference.chat_local/3` → `Inference.Chat.do_chat_local/3` se
colapsa a solo-`{:error, ...}`, cuando las specs y las sondas, una a una, dicen
que el camino de éxito existe.

## Por qué no se maquilla

Cualquier forma de esquivar esto rompe algo:

- **`apply/3`** para que dialyzer no lo vea: es exactamente el trick que el
  propio repo condemna en un comentario de `detector.ex` — *"an `apply/3` here was
  only there to silence the compiler and hid the fact that a missing Trebejo
  silently degraded"*.
- **Un `case` laxo** que no distinga éxito de error: el fallo no lo vería nadie
  hasta producción, y esta función existe para no perder el historial.
- **Dejar el gate en rojo**: la regla del repo es que un gate rojo no se
  maquilla; se arregla o se dice por qué.

## Qué necesito

Una de estas dos, y es una decisión de dueño:

1. **Escribir el contrato real de la capa de inferencia** (`Candil.Inference` y
   `Candil.Inference.Chat`), que hoy no tiene specs en su mayoría. Es deuda de
   spec de otro carril, y corregirla a ciegas es inventar.
2. **Migrar `Candil.Agent` a `Candil.Context`** y hacer la F6 de otra manera.
   Eso tiene su propia pregunta sin responder: **¿qué `consumer` es un agent, y
   qué `session_id` usa?** No está escrito en ningún documento, y no se decide de
   paso.

## Lo que sí se entrega de esta sub-tarea

Todo lo demás de D8 está hecho, verificado y commiteado: el módulo
`TokenEstimator` movido a `Candil.Context`, `Conversation.Context` borrado sin
deprecación, y el aviso de D8 escrito en el moduledoc.
