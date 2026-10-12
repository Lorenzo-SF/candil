# Cómo seguir desde tu maquina

> Para el agente de `mcode` (o el que sea) que se abra este repo en tu
> ordenador. **Lo que hay que saber antes de tocar nada, y en qué orden.**
>
> 2026-10-12

---

## 0 · Por donde leer, en este orden

| # | Documento | Qué te dice |
|---|---|---|
| 1 | [`08-decisiones`](../08-decisiones/) | **qué se decidió y por qué**, included las que se tomaron a mitad de fase |
| 2 | [`09-deuda-y-pendientes`](../09-deuda-y-pendientes/) | **qué falta, qué está roto, y qué no se ha podido probar** |
| 3 | [`02-orden`](../02-orden/) | la secuencia de fases y qué desbloquea qué |
| 4 | [`06-capacidad-y-politica`](../06-capacidad-y-politica/) | la capacidad, los modos y la decisión del refusal |

Si solo te lees uno, el **2**.

---

## 1 · La rama de la que seguir

| | |
|---|---|
| **Rama de trabajo** | **`fase-4-politica-turno`** — código terminado, **967 tests en verde**, PR #48 **abierto y sin mergear** |
| `main` | `5a28e71` — 936 tests en verde, la fase 4 **sin** entrar |

```bash
cd ~/workspace/github/zaguan/candil
git checkout fase-4-politica-turno
git pull
```

**Por qué no está mergeada**: el código está verde, pero **la cola no se ha
probado con un destino realmente exclusivo**. Y ese es justo el punto: con
modelos remotos falsos un turno dura microsegundos, y con un modelo de verdad
dura segundos. **Si el reloj no mide la inferencia, la política no sirve y el
verde no lo habría detectado.**

---

## 2 · Lo primero: el entorno

```bash
. ~/tools/env.sh          # PATH, UTF-8, HEX_MIRROR, MIX_BUILD_ROOT
export CANDIL_DATA_DIR=$(mktemp -d)   # SIEMPRE
```

Y dos cosas que **no son de Candil** pero decidirán si el rojo es real:

```bash
sudo pacman -S zip        # sin esto, 12 tests de Precompiled fallan con :enoent
# cmake y ninja: en /workspace/tools/cmake-root y en el PATH de env.sh
```

> Sin `cmake` la suite corre **878** tests en vez de 882, porque cuatro tests
> **solo existen si hay `cmake`**. Comparar dos suites distintas produce
> conclusiones falsas — ya pasó.

---

## 3 · La medicion, en un comando

```bash
bash scripts/medir-en-mi-maquina.sh
```

Deja todo en **un fichero** en tu `~/`, que es lo que hay que pegarle al agente.

Las tres secciones, y qué se hace con cada una:

- **A · el suelo.** La suite y los gates. Si esto está rojo, lo demás no cuenta.
- **B · las capas del enrutado.** Corre sola con vectores falsos. **La sección 2
  hay que rellenarla** con tu embedder, tu clasificador y tus prompts.
- **C · la cola contra una GPU real.** No se puede automatizar: necesita tu
  modelo cargado. El script te dice **qué mirar y qué significaría cada cosa**,
  y lo que más importa es esto:
  > **Si un turno dura 0 ms con un modelo de verdad, el reloj no está midiendo la
  > inferencia, y la política no sirve de nada.** Es el fallo más probable, y
  > ningún test lo ve.

---

## 4 · Lo que hay que decidir, y es del dueño

1. **El defecto del refusal** — `fail` · `wait` · `degrade`. Configurable, pero
   **el defecto no está puesto**, y **bloquea la fase 5**.
2. **La métrica del tribunal** — qué fracción de decisiones resolvió el motor
   estático. **No existe la instrumentación**, y `DISENO-MOTOR` §10 la pone como
   condición antes de meter un LLM como clasificador.

---

## 5 · Lo que no hay que hacer

- **No mergear la fase 4** sin haber medido §3-C. El verde de los tests no cubre
  el caso real: un destino de mentira no se parece a una GPU.
- **No borrar las 17 ramas sin mergear.** En Arrea se verificó que eran más
  antiguas que `main`; aquí **no**, y traen la estructura vieja `proyecto 4.0/`.
  Que traigan más líneas no significa que aporten nada, y borrarlas sin mirar el
  contenido es el error del `git add -A` de esta semana.
- **No confiar en un rojo que no se reproduce.** En este repo se ha pagado tres
  veces: los 4 tests de cmake, la suite escribiendo en `~/.candil`, y los 12 de
  `zip`.
- **No poner un clasificador ni un embedder por defecto.** El proyecto no lanza
  modelos que el usuario no le ha pedido.
