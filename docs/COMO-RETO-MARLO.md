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

## Lo primero al sentarte

```bash
cd ~/workspace/github/zaguan/candil
git pull
. ~/tools/env.sh                      # PATH, UTF-8, HEX_MIRROR, MIX_BUILD_ROOT
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
