# 04 · Módulos

> Los cinco módulos del producto. Cada uno es un destino, y cada uno se escribe
> siguiendo el plano de [`03-convenciones`](../03-convenciones/README.md).
>
> **Este índice no se lee de un tirón.** Cada módulo dice qué necesita de los
> demás, y el orden está en [`02-orden`](../02-orden/README.md).

---

## Los cinco, en una frase cada uno

| # | Módulo | Qué es, en una frase |
|---|---|---|
| **01** | [Routing y ciclo de vida](01-routing-y-ciclo-vida/) | Decide a qué modelo va cada prompt, y que los motores ocupen la GPU solo cuando hacen falta |
| **02** | [Contexto compartido](02-contexto-compartido/) | Que el mismo hilo sobreviva al cambio de modelo, sin reenviar el historial entero cada vez |
| **03** | [RAG](03-rag/) | Que el modelo responda con lo que está en tus documentos, y con la cita de dónde |
| **04** | [MCP](04-mcp/) | Que las herramientas de Candil sirvan a cualquier cliente, y que las de otros sirvan a Candil |
| **05** | [Agentes](05-agentes/) | Que un agente sea un proceso con vida propia, no un `while true` |

---

## La diferencia que separa este bloque del resto

> **«Candil tiene un MCP»** y **«Candil deja construir un MCP»** son dos
> productos distintos, y la diferencia no es escribir más código: es que el
> segundo se hace con **behaviours y registros**, no con módulos con `def`.

El criterio de aceptación del segundo es una frase:

> **Un tercero define esto y funciona sin tocar Candil.**

Y se comprueba con un test que solo se puede escribir si el punto de extensión
existe de verdad. Si el test necesita tocar Candil, es que no es un framework.

## Cómo están conectados

```
01 routing ──┬──► 02 contexto        (cada paso del agente es una decisión)
             └──► 05 agentes         (el agente pregunta al router por paso)

04 MCP ──────┬──► cualquier agente   (las herramientas son el mismo registro)
             └──► 05 agentes

03 RAG ────────► 02 contexto         (la memoria común vive en el RAG)
```

**Lo que no está en ninguno de los cinco, y es el eje de todo**: el scheduler.
Vive en [`02-orden`](../02-orden/README.md) porque es lo que ordena las fases, no
lo que construye un módulo. Y no se puede empezar hasta que se decida si el
reparto es round-robin justo o FIFO con VIP.

---

## Lo que estos cinco módulos tienen en común

1. **Todos dependen de behaviours que aún no existen**: embedder, chunker,
   provider, clasificador, scheduler. Están en [`01-inventario`](../01-inventario/README.md)
   §2, y son la fase 1 del orden.
2. **Ninguno se cierra con el CLI.** El criterio es `mix run -e`.
3. **Todos se verifican en la máquina del dueño**, no en el CI. Es la lección de
   esta semana, escrita tres veces seguidas.
