# `proyecto 4.0/auditoria/` — la documentación corregida

> **Qué es esto.** El juego de documentos que la auditoría del 2026-10-03 revisó
> y corrigió: los README de fase con los cuatro niveles de verificación, el
> informe de las 9 contradicciones, y las enmiendas v4.1.
>
> **Fecha de la auditoría**: 2026-10-03 · **Base medida en ese día**:
> `main` @ `7fc0920`, **705 tests + 26 doctests, 0 fallos, 66.2 %**, 8 gates.

## Por qué vive en un directorio aparte

`proyecto 4.0/fases/` son los README **tal como se escribieron**, y se quedan
quietos a propósito: son el registro de lo que había cuando se escribió cada
fase, y `git log` ya los conserva. Este directorio es la **versión corregida**.

Los dos juegos convivían solo dentro de un ZIP de entrega, que es
exactamente la razón de que las cifras derivaran: nadie los tenía delante al
trabajar, y un documento que nadie puede leer no corrige nada. Ahora están en el
repo, junto al código que describen.

## Por dónde se entra

| | |
|---|---|
| **1** | `RETOMAR.md` — el punto de entrada. Empieza por §1 (medir) y §2 (la tabla de veredictos, ya rellena) |
| **2** | `PLAN-EJECUCION.md` — el ciclo, los niveles de razonamiento, las 4 capas |
| **3** | `00-INFORME-AUDITORIA.md` — las 9 contradicciones, y sobre todo **A1** y **A2**, que bloquean F9 y F10 |
| **4** | el README de la fase que toques: `fase-N-README.md` |
| — | `v4.1/` — las enmiendas al diseño. **Se leen al empezar F6** |
| — | `00-PROMPT-SESION-NUEVA.md` — el prompt completo de arranque |

`ORIGINAL/` no está aquí: los documentos sin tocar ya viven en
`proyecto 4.0/original/` y en `proyecto 4.0/fases/`.

## Lo que esta copia ya corrige

Las tres cosas que hacían que un agente implementing una fase **distinta** de la
que creía:

1. **Los paths de los criterios de aceptación.** Seis de ellos apuntaban a
   `test/candil/<fase>/`, y **ningún directorio de ese nombre existe**: los tests
   son planos, `router_test.exs` y compañía. `mix test` abortaba con
   *«Paths given to "mix test" did not match any directory/file»*. Los seis se
   han cambiado por paths que **se han ejecutado** antes de escribirlos.
2. **La base de tests.** Decía 702, luego 687 + 26, luego 623 + 25. Ninguna era
   cierta. La base real es **705 + 26**, y ahora cada README dice que hay que
   **volver a medirla al abrir la rama** en lugar de fiarse de un número escrito.
3. **La columna de veredictos de `RETOMAR.md` §2**, que era el mandato literal
   del prompt de arranque y estaba vacía. Está rellena con salida real.

## Lo que NO se ha arreglado, a propósito

- **A1 · la revisión del protocolo MCP.** El código está escrito contra
  `2025-11-25` (Legacy); la Current es `2026-07-28` y eliminó el handshake
  `initialize`. Es una decisión de diseño y no se toma de paso.
- **A2 · el diseño del RAG.** Dos documentos, ocho divergencias, dos RAG
  distintos. También es decisión.
- **A4 · el cierre a `main`.** Ver la nota de abajo.

⚠ **A4 sigue abierta y toca este mismo trabajo.** `main` tiene branch protection
con 1 approving review, y el PAT es admin. Mergear a `main` saltándosela
significa saltarse la única protección que queda en el repo. Por eso el trabajo de
esta sesión está en la rama `cierre-f0-f5` y **no se ha mergeado**.
