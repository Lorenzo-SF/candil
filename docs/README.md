# Candil — documentación

> **Este es el punto único de conocimiento del proyecto.**
>
> Si algo está aquí y no en otro sitio, está aquí porque no tiene otro sitio. Si
> algo está en otro sitio y también aquí, es un error: una verdad, un sitio.
>
> **Rama**: `main` · sin ramas de trabajo abiertas
> **Medido el 2026-10-13**: **976 tests + 27 doctests, 0 fallos** · credo 0 ·
> dialyzer 0 · CI en verde. Fases cerradas: 0, 1, 2, 3 y 4.
>
> **Si vienes de otro sitio y solo vas a leer una cosa**:
> [`COMO-RETO-MARLO.md`](COMO-RETO-MARLO.md) — y si eres un agente sin nadie
> delante, ve a su sección *«si eres un agente y no hay nadie delante»*, que
> lista lo que sí se puede hacer sin GPU.
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

## Y, más concreto: cuál es el centro de gravedad

> **El centro de gravedad de Candil es el enrutado. La inferencia local es un
> backend más.**

Escrita el 2026-10-11, y no es una frase de adorno. El diseño del motor de
decisión —`DISENO-MOTOR.md`— **no menciona GPU, CUDA, VRAM ni device ni una
sola vez**, mientras que el router ya distingue los tres tipos de destino
(`:local`, `:remote`, `:external`). La abstracción ya estaba arriba; lo que no
estaba escrito era **qué papel juega lo local**.

Y esa frase cambia el orden de las fases, porque el orden anterior daba por
supuesto que todo era local:

- un usuario que **solo llama a APIs** se salta motores, builds, VRAM, scheduler
  y descubrimiento de dispositivos. Que se lo salte es correcto. Que el plan no
  lo dijera, no.
- el trabajo local que **sí** existe se conserva, aparcado y medido, en
  [`07-local-aparcado/`](07-local-aparcado/), no borrado.

La consecuencia práctica: **el camino caliente no pasa por el planificador.** Con
la política por defecto `one_for_one` —sin cola, porque es lo correcto cuando
el destino no es exclusivo— la política es una extensión, no el camino.

Todo el razonamiento, con las mediciones que lo sostienen, está en
[`06-capacidad-y-politica/`](06-capacidad-y-politica/README.md).

## Por dónde se empieza

| Si quieres… | Ve a |
|---|---|
| Saber **por qué** el enrutado es el centro | [`06-capacidad-y-politica/`](06-capacidad-y-politica/) |
| Saber qué hay **hoy**, medido | [`01-inventario/`](01-inventario/) |
| Saber **en qué orden** se hace y por qué | [`02-orden/`](02-orden/) |
| Saber **cómo se escribe** una fase | [`03-convenciones/`](03-convenciones/) |
| Saber **qué es** cada módulo del producto | [`04-modulos/`](04-modulos/) |
| Saber cómo **Arrea** está hecho y cómo se usa | [`00-arrea/`](00-arrea/) |
| Saber qué se hizo con lo local y qué queda | [`07-local-aparcado/`](07-local-aparcado/) |
| Saber **por qué** algo es como es | [`08-decisiones/`](08-decisiones/) |
| Saber **qué falta** y qué no está probado | [`09-deuda-y-pendientes/`](09-deuda-y-pendientes/) |
| Ver el **esqueleto** de `candil.toml` | [`05-cli/config/`](05-cli/config/) |

**El orden no es el de los números.** `00-arrea` va primero porque Arrea es el
chasis y todo lo que se construya encima hereda sus límites. El `01` va segundo
porque **sin saber qué hay, no se puede planificar**.

---

## Los diez bloques

```
00-arrea/          el chasis. Cómo está hecho y qué garantiza
01-inventario/     qué hay, qué no, y qué falta para llegar
02-orden/          la secuencia y sus dependencias
03-convenciones/   TDD, SDD, gates, y el plano de cada fase
04-modulos/        los cinco módulos del producto
05-cli/            el ejecutable. Al final, con Alaja
06-capacidad-y-politica/   qué es una capacidad y quién va primero
07-local-aparcado/         lo que se hizo en local y lo que queda
08-decisiones/             qué se decidió, cuándo, por qué y qué costó
09-deuda-y-pendientes/     deuda, problemas abiertos, y lo que falta por probar
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

## Estado, medido el 2026-10-12

| | |
|---|---|
| `main` | `b43b56e` · **976 tests + 27 doctests, 0 fallos** · credo 0 · dialyzer 0 · CI en verde |
| Rama de trabajo | **ninguna.** La 4 está mergeada y medida |
| Gates | format · compile `--warnings-as-errors` · credo · test (`--seed 0`) · dialyzer |
| Fases cerradas | 0 (medir) · 1 (behaviours) · 2 (`Arrea.Resource`) · 3 (el enrutado) · **4 (la política de turnos)** |
| La 4, contra GPU | **medida el 2026-10-13**: el turno dura 6655 ms sobre una inferencia de 6793 ms |
| Siguiente | **5 · el refusal**, bloqueada por la decisión abierta nº1 |

> **Comparar dos suites exige que sean la misma, y ahora lo son.** Antes la
> suite corría **878 en vez de 882** sin `cmake` en el PATH —cuatro tests de
> `source_real_test.exs` no se definían—, y **doce tests más caían sin el
> binario `zip`**. Los dos están arreglados: 976 con y sin `cmake`, y sin
> depender de ningún binario que el proyecto no instale. Ver el
> [`CHANGELOG`](../../CHANGELOG.md).

---

## Lo que hay aquí

| Bloque | Qué contesta |
|---|---|
| [`00-arrea`](00-arrea/) | el chasis: cómo está hecho y qué garantiza |
| [`01-inventario`](01-inventario/) | qué hay, qué no, y los cuatro hallazgos de la fase 0 |
| [`02-orden`](02-orden/) | **la secuencia y sus dependencias** |
| [`03-convenciones`](03-convenciones/) | cómo se escribe una fase: TDD, gates, SDD |
| [`04-modulos`](04-modulos/) | qué es cada módulo del producto |
| [`05-cli`](05-cli/) | el ejecutable, al final |
| [`06-capacidad-y-politica`](06-capacidad-y-politica/) | **qué es una capacidad y quién va primero** |
| [`07-local-aparcado`](07-local-aparcado/) | el trabajo local, con su estado y su motivo |
| [`08-decisiones`](08-decisiones/) | **qué se decidió, cuándo, por qué y qué costó** |
| [`09-deuda-y-pendientes`](09-deuda-y-pendientes/) | **deuda, problemas abiertos, y lo que falta por probar** |

**Si acabas de llegar y tienes una máquina delante, empieza por
[`09-deuda-y-pendientes` §2](09-deuda-y-pendientes/README.md)**: es la lista
exacta de lo que se ha escrito sin poder ejecutarse, y que desde el 2026-10-12
sí se puede.

---

## Las decisiones abiertas

Cinco siguen abiertas. Todas están marcadas en su sitio, y todas en
[`08-decisiones` D-11](08-decisiones/README.md).

1. **Cuando algo está ocupado y no cabe, ¿qué hace Candil?** — `fail`, `wait` o
   `degrade`. Configurable, pero **el defecto no está puesto**. **Es la que
   bloquea la fase 5** y es del dueño. Está en
   [`06-capacidad-y-politica` §4](06-capacidad-y-politica/README.md).
2. **¿La memoria compartida comparte historial o solo patrones?**
3. **¿Quién escribe la verdad de la VRAM?** — medido el 2026-10-10:
   `Detector.Devices` la **lee**; escribirla sigue sin dueño.
4. **¿`Candil.Provider` es un registro o una lista cerrada?**
5. **¿El camino de librería entra en las fases, o se queda fuera?**

**Y la sexta ya tiene respuesta.** ¿Entra un LLM como clasificador? `§10` de
`DISENO-MOTOR` ponía un tribunal antes de meterlo, y ese tribunal **ya se ha
sentenciado** — con la métrica de A-1 y modelos reales:

```
lo resolvió la política estática .... 2/12  = 16.7%
hubo que llamar al LLM ............. 10/12 = 83.3%
```

`§10` pone la barra en el 60%. **No se llega.** La conclusión del propio diseño
es que hay que **arreglar las señales antes de meter un modelo**, y eso es
política de quien lo usa, no del motor. Lo que queda por decidir es *qué*
señales, y hasta dónde — no *si* hay un problema. La métrica vive en
`[:candil, :router, :decision]` y se mide con
[`scripts/tribunal-real.exs`](../../scripts/tribunal-real.exs).
