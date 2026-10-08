# Candil — documentación

> **Este es el punto único de conocimiento del proyecto.**
>
> Si algo está aquí y no en otro sitio, está aquí porque no tiene otro sitio. Si
> algo está en otro sitio y también aquí, es un error: una verdad, un sitio.
>
> **Rama**: `docs-v2` · **Base**: `main` en `e168ccd` (fase 7 mergeada)
> **Medido**: 88 módulos · 65 ficheros de test · **824 tests + 27 doctests, 0 fallos**
>
> ⚠️ **[La fase 0 ya se hizo, y encontró cuatro cosas que el plan daba por
> buenas.](01-inventario/HALLAZGOS-FASE-0.md)** El proveedor remoto nunca había
> salido a la red, el bucle ReAct de los agentes no cerraba jamás, el RAG son
> cinco stubs, y **el refusal de VRAM no existe**. Ningún test lo vio: pasaban
> porque probaban lo que el test puesto al lado hacía.

---

## La tesis

Candil es un **framework de IA**, y el CLI es una de sus aplicaciones.

Al revés sería un programa con un ejecutable. Esto es una librería a la que
después se le añade un binario, y esa distinción decide casi todo lo que está
dentro — en particular, por qué el CLI no aparece hasta el final del plan.

## Por dónde se empieza

| Si quieres… | Ve a |
|---|---|
| Saber qué hay **hoy**, medido | [`01-inventario/`](01-inventario/) |
| Saber **en qué orden** se hace y por qué | [`02-orden/`](02-orden/) |
| Saber **cómo se escribe** una fase | [`03-convenciones/`](03-convenciones/) |
| Saber **qué es** cada módulo del producto | [`04-modulos/`](04-modulos/) |
| Saber cómo **Arrea** está hecho y cómo se usa | [`00-arrea/`](00-arrea/) |
| Ver el **esqueleto** de `candil.toml` | [`05-cli/config/`](05-cli/config/) |

**El orden no es el de los números.** `00-arrea` va primero porque Arrea es el
chasis y todo lo que se construya encima hereda sus límites. El `01` va segundo
porque **sin saber qué hay, no se puede planificar**.

---

## Los seis bloques

```
00-arrea/          el chasis. Cómo está hecho y qué garantiza
01-inventario/     qué hay, qué no, y qué falta para llegar
02-orden/          la secuencia y sus dependencias
03-convenciones/   TDD, SDD, gates, y el plano de cada fase
04-modulos/        los cinco módulos del producto
05-cli/            el ejecutable. Al final, con Alaja
```

## Las cuatro reglas que no se negocian

**1 · Una fase no se cierra por el CLI.**
El criterio es `mix run -e '…'` o un test. `./candil algo` es confirmación
secundaria, y solo cuando el comando existe.

**2 · Una verdad, un sitio.**
El catálogo de modelos está en el TOML y en ningún otro lado. El estado de lo que
corre está en `instances.json` y en ningún otro lado. Las dos veces que ha habido
dos sitios, ha divergido. **Once tests leían el `candil.toml` de una persona** y
creían que estaban probando el suyo.

**3 · Lo que no se ejecuta, no está probado.**
Un test que nadie ha corrido en la máquina real es una hipótesis. Un script que
solo mira un exit code es peor. VRAM, puertos, y que el modelo **conteste**.

**4 · La plantilla se genera, no se escribe.**
El esqueleto de `candil.toml` sale del schema y **se valida a sí mismo** antes de
escribirse. Ningún `candil.toml` real vive en el repo.

---

## El ciclo que se repite

Cada fase de este proyecto sale con la misma forma:

1. Los tests están en verde.
2. Alguien ejecuta el binario en su máquina.
3. **El binario miente dos veces**: algo dice `:ok` que no fue `:ok`, o no
   encuentra un fichero que existe.

Esta semana: la API inventada de Alaja, los consumers que no se leían del toml,
y el «pin» que en realidad era un solo candidato. Los 800 tests estaban en verde
las tres veces.

> Por eso la primera puerta de cada fase no es `mix test`. Es **alguien lo
> ejecuta**.

---

## Lo que NO está aquí, y por qué

| | |
|---|---|
| **Ningún `candil.toml` real** | El tuyo está en `~/.config/candil/candil.toml`. Aquí solo el esqueleto generado y un fixture de test |
| **`proyecto 4.0/`** | Borrado. 49 ficheros que eran un proyecto entero dentro del repositorio. Está en el historial |
| **Los audits viejos** | Los que siguen en pie están recogidos en los bloques. Los que no, no |
| **Una cifra sin medir** | Si aquí hay un número, sale de ejecutarlo |

## Estado de esta rama

| | |
|---|---|
| Gates | format · compile `--warnings-as-errors` · credo strict · test · escript → **limpio** |
| Tests | **800 + 27 doctests, 0 fallos** |
| Escrito | `00-arrea` · `01-inventario` · `02-orden` · `03-convenciones` · `04-modulos` (índice) |
| En curso | los cinco módulos de `04-modulos/` |

## Las cinco decisiones abiertas

Ninguna cerrada. Todas están marcadas en su sitio, y **la primera bloquea la
fase que ordena todo lo demás**.

1. **¿Round-robin justo o FIFO con VIP?** — decide qué es la línea de cajas.
   Está en [`02-orden` §7](02-orden/README.md).
2. **¿La memoria compartida comparte historial o solo patrones?**
3. **¿Quién escribe la verdad de la VRAM, Candil o Arrea?**
4. **¿`Candil.Provider` es un registro o una lista cerrada?**
5. **¿El camino de librería entra en las fases, o se queda fuera?**
