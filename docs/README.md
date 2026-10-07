# Candil — documentación

> Este `README.md` es el índice. Cada carpeta es un bloque de trabajo y cada
> bloque tiene su propio `README.md`.
>
> **Rama**: `docs-v2` · **Base**: `main` en `e168ccd` (fase 7 mergeada)

---

## La tesis, en una frase

Candil es un **framework de IA**, y el CLI es una de sus aplicaciones.

Al revés sería un programa con un ejecutable. Esto es una librería a la que
después se le añade un binario, y esa es la diferencia que decide casi todo lo
que hay dentro.

## El orden, y por qué en este orden

| # | Bloque | Qué resuelve | Por qué aquí |
|---|---|---|---|
| **00** | [`arrea/`](arrea/) | Cómo está hecho Arrea y cómo se usa | Va primero porque **Arrea es el chasis**. Entenderlo después de escribir código sobre él es hacerlo tarde |
| **01** | [`inventario/`](inventario/) | Qué hay, qué no, qué falta | Antes de planificar hay que saber sobre qué se.planifica |
| **02** | [`orden/`](orden/) | Orden de implementación y **prerrequisitos** | Un objetivo que depende de otro que no existe no es un objetivo: es una sorpresa |
| **03** | [`convenciones/`](convenciones/) | TDD, SDD, y cómo se escribe cada fase | Antes de la primera línea de la primera fase |
| **04** | [`modulos/`](modulos/) | Los cinco módulos del producto | El destino. Se lee, no se ejecuta de un tirón |
| **05** | [`cli/`](cli/) | El ejecutable, con Alaja | **El último.** Ninguna fase se cierra por el CLI |

## Las tres reglas que no se negocian

**1 · Una fase no se cierra por el CLI.**
El criterio de aceptación es `mix run -e '…'` o un test. `./candil algo` es
confirmación secundaria, y solo a partir de que exista el comando.

> Por qué: el bug del «pin que no existía» salió ejecutando el binario en la
> máquina del dueño, no leyendo los tests. Los 800 tests estaban en verde.

**2 · Una verdad, un sitio.**
El catálogo de modelos está en el TOML y en ningún otro lado. El estado de lo que
está corriendo está en `instances.json` y en ningún otro lado. Cada vez que
hemos tenido dos sitios, ha divergido.

**3 · Lo que no se puede ver, no se ha probado.**
Un test que nadie ha ejecutado en la máquina real es una hipótesis. Un script
que solo mira un exit code es peor. VRAM, puertos, y que el modelo **conteste**
algo.

## Lo que NO está aquí

- **Ningún `candil.toml` real.** El tuyo está en `~/.config/candil/candil.toml`
  y no entra en el repo. El esqueleto con todo comentado vive en
  [`05-cli/config/`](05-cli/config/) y se **genera** desde el schema.
- **Nada de `proyecto 4.0/`.** Borrado. Está en el historial, y lo que no
  seguía en pie ya estaba desfasado.
- **Ninguna afirmación sin medir.** Si aquí pone un número, sale de ejecutarlo.

## Lo que sigue de largo

- [`01-inventario/`](01-inventario/) está por escribir: es el siguiente bloque.
- [`03-convenciones/`](03-convenciones/) define TDD y SDD, y tiene que estar
  escrito **antes** de la primera fase, no después.
- La decisión de [la política de reparto](02-orden/) — round-robin justo o FIFO
  con VIP — sigue **abierta**, y bloquea el bloque 8b.
