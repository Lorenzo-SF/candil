# Candil — cómo retomarlo

> **Estado a 2026-10-12, medido, no supuesto.** `main` `2b5d766` · **967 tests +
> 27 doctests, 0 fallos** · credo 0 · dialyzer 0 · CI en verde.
> Rama de trabajo: **ninguna**. Todo está en `main`.

---

## Si solo te lees una cosa

**`docs/09-deuda-y-pendientes/README.md`** — es la lista de lo que falta, de lo
que está roto, y de **lo que se escribió sin poder probarlo** y que desde el
2026-10-12 ya se puede probar porque hay una máquina con una RTX 5080 delante.

---

## Los cinco documentos, en orden de lectura

| # | Documento | Qué contesta |
|---|---|---|
| 1 | [`09-deuda-y-pendientes`](09-deuda-y-pendientes/) | **qué falta, qué está roto, qué no está probado** |
| 2 | [`08-decisiones`](08-decisiones/) | **qué se decidió, cuándo, por qué, y qué costó** — incluidas las que se tomaron a mitad de fase |
| 3 | [`02-orden`](02-orden/) | la secuencia de fases y qué desbloquea qué |
| 4 | [`06-capacidad-y-politica`](06-capacidad-y-politica/) | qué es una capacidad, los modos de turno, y la decisión del refusal |
| 5 | [`01-inventario`](01-inventario/) | qué hay hoy, y los cuatro hallazgos de la fase 0 |
| — | [`COMO-SEGUIR.md`](COMO-SEGUIR.md) | este fichero, y lo que **no** hay que hacer |

---

## Dónde está cada cosa

| Fase | Qué | Estado |
|---|---|---|
| 0 | Probar lo que existe sin probar | ✅ |
| 1 | Los behaviours que faltaban | ✅ |
| 2 | `Arrea.Resource` — la forma de una capacidad | ✅ en **Arrea 4.0.0**, publicada en Hex |
| 3 | El enrutado: las capas `:embedding` y `:llm` | ✅ |
| **4** | **La política: quién va primero** | ✅ **mergeada hoy**, 967 tests |
| 5 | El refusal, en los tres tipos | ⬜ **bloqueada por una decisión tuya** |
| 6-12 | RAG · MCP · Gateway · mesa camilla · agentes · stats · CLI | ⬜ |

---

---

## Si eres un agente y no hay nadie delante: empieza por aquí

Lo de arriba **necesita a una persona con una GPU delante**. Si te dejan este
repo sin nadie, estas cinco cosas **se pueden hacer ya, en `main`, sin máquina
especial**, y todas salen de [`09-deuda-y-pendientes`](09-deuda-y-pendientes/):

| # | Qué | Por qué se puede hacer | Dónde |
|---|---|---|---|
| **A-1** | **La métrica del tribunal**: un evento de telemetría en la decisión del router, con **la capa que la produjo** | es instrumentación pura, no necesita modelo | `lib/candil/router/decision_engine.ex`, `lib/candil/telemetry.ex` |
| **A-2** | **T-1**: que los 12 tests de `Precompiled` no dependan del binario `zip` | hoy fallan en cualquier máquina sin `zip`, y el rojo no habla de Candil | `test/candil/build/precompiled_test.exs` |
| **A-3** | **T-2**: que los 4 tests de cmake no **desaparezcan** si no hay `cmake` | hoy la suite corre 878 en vez de 882, y comparar dos suites distintas produce conclusiones falsas | `test/candil/build/source_real_test.exs` |
| **A-4** | **T-4**: quitar de `.credo.exs` el check `NestedModules`, que no existe en Credo 1.7.19 | ruido en cada ejecución | `.credo.exs` |
| **A-5** | **T-5**: revisar **una a una** las 17 ramas sin mergear, y borrar las que no aporten | en Arrea se pudo hacer porque eran **más antiguas** que `main`; aquí **no** se ha comprobado | GitHub |

### La más urgente de las cinco: A-1

`DISENO-MOTOR.md` §10 pone una condición antes de meter un LLM como
clasificador: **se mide qué fracción de decisiones resolvió la política**, y si
es el 60% en vez del 97%, el motor estático está mal hecho y hay que arreglarlo
antes de meter un modelo. **Esa métrica no existe**, así que hoy nadie puede
saber si el clasificador está justificado.

**Y una trampa que ya se ha pagado**, porque es fácil caer en ella:
**tomar el turno con `enter/2` también cuenta como turno servido y emite su
propio evento.** Una petición que espera son **tres** eventos, no dos: el de
`run/3` que no espera, el de `enter/2` que toma el turno, y el de la que espera
de verdad. Un contador mal pensado cuenta turnos donde cuentan peticiones, y
sale un número que no significa nada.

### Lo que **no** debes hacer sin que nadie te lo pida

- **No implementes el refusal** (fase 5). Está **bloqueada por una decisión del
  dueño**: `fail`, `wait` o `degrade`. Hay tres respuestas defendibles y no es
  una decisión de diseño.
- **No implementes `rest_for_one`.** Está aplazado **a propósito**: solo tiene
  sentido cuando exista un destino que pueda ceder el turno antes de terminar.
- **No pongas un clasificador ni un embedder por defecto.** El proyecto no
  lanza modelos que el usuario no le ha pedido.
- **No abras PR sin mirar su CI antes de pedir el merge**, y **no hagas push
  directo a `main`** ni con un PAT que lo permita.

## Lo primero al sentarte

```bash
git clone https://github.com/Lorenzo-SF/candil.git
cd candil && git checkout main && git pull
```

**El toolchain: búscalo, no lo des por puesto.** Una version anterior de este
documento decia `. ~/tools/env.sh` sin mas, y **esa ruta estaba inventada**:
cada maquina lo tiene en un sitio. Se localiza asi:

```bash
which mix || ls -d ~/.asdf ~/tools /opt/candil-build /workspace/tools 2>/dev/null
```

| Donde este | Que sourcing |
|---|---|
| `~/.asdf` (asdf) | `. "$HOME/.asdf/asdf.sh"` y ya |
| `~/tools/env.sh` o similar | `. ~/tools/env.sh` |
| nada de los dos | hay que reconstruir: ver abajo |

**Y `MIX_BUILD_PATH` no se toca nunca.** Es la ruta **literal** del build dir y
anula `MIX_BUILD_ROOT`: con las dos puestas, dev y test comparten un solo
`_build`, y aparece un `mox`/`excoveralls` podado y **70 tests "no process:
Mox.Server"** que no tienen nada que ver con lo que has tocado.

```bash
export CANDIL_DATA_DIR=$(mktemp -d)   # SIEMPRE
sudo pacman -S zip                    # sin esto, 12 tests de Precompiled fallan
```

Y un recordatorio que ya ha_costado caro tres veces:

> Sin `cmake` la suite corre **878** tests en vez de 882, porque cuatro tests
> **solo existen si hay `cmake`**. Comparar dos suites distintas produce
> conclusiones falsas. cmake y ninja están en `/workspace/tools/cmake-root`.

---

## Lo que hay que hacer, en orden

### 1 · Medir la cola con un destino de verdad

```bash
bash scripts/medir-en-mi-maquina.sh
```

Deja un único informe en tu `~/`. La sección **C** es la que importa y no se
puede automatizar: necesita tu modelo cargado.

> **Si un turno dura 0 ms con un modelo de verdad, el reloj no está midiendo la
> inferencia y la política no sirve de nada.** Es el fallo más probable, y
> ningún test lo ve — porque con modelos remotos falsos no hay inferencia que
> medir.

### 2 · Rellenar la sección 2 de `scripts/router-layers-check.exs`

Con tu embedder, tu clasificador y tus prompts. Con un embedder de mentira el
recuento significa nada, y el propio script lo avisa.

### 3 · Decidir el refusal

`fail` · `wait` · `degrade`. **Configurable, pero el defecto no está puesto**, y
**bloquea la fase 5**.

### 4 · Instrumentar el tribunal

La métrica de **qué fracción de decisiones resolvió el motor estático** no
existe. Y `DISENO-MOTOR` §10 la pone como **condición** antes de meter un LLM
como clasificador: si la política resuelve el 97%, el LLM es ruido caro; si
resuelve el 60%, el motor estático está mal hecho y hay que arreglarlo antes.

> **Trampa ya pagada:** el evento de turno existe, pero **tomar el turno cuenta
> como turno servido y emite su propio evento**. Una petición que espera son
> **tres** eventos, no dos. Un contador mal pensado cuenta turnos donde cuentan
> peticiones.

---

## Lo que NO hay que hacer

- **No confiar en un rojo que no se reproduce.** En este repo se ha pagado tres
  veces: los 4 tests de cmake, la suite escribiendo en el `~/.candil` del
  developer, y los 12 de `zip`.
- **No borrar las 17 ramas sin mergear.** En Arrea se verificó que eran más
  antiguas que `main` y se pudieron borrar. Aquí **no se ha comprobado**, y
  traen la estructura vieja `proyecto 4.0/`. Que traigan más líneas no significa
  que aporten nada.
- **No poner un clasificador ni un embedder por defecto.** El proyecto no lanza
  modelos que el usuario no le ha pedido, y un default que arranca un LLM por su
  cuenta consume GPU sin que nadie lo haya pedido.
- **No creerse el ejemplo de la GPU de `Bulkhead`.** `12 + 1,8 = 13,8` sí cabe en
  16, y sin embargo el ejemplo dice que no — porque **falta la caché KV**. Un
  modelo no ocupa solo sus pesos.
