# Los siete bugs de arranque — 2026-10-05

> **Por qué existe este documento.** Una tarde entera buscando un `exit 1` con
> la VRAM quieta. Seis bugs reales de Candil, arreglados y verificados. Y al
> final, un flag inventado en el `candil.toml` que era el problema de verdad.
>
> Los seis eran de Candil. El séptimo no, y hacía exactamente el mismo ruido.

---

## Resumen

| # | Qué pasaba | Dónde estaba el bug | Quién lo vio |
|---|---|---|---|
| 1 | `run` no arrancaba **nada** | Candil, `CLI/Lifecycle` | la VRAM quieta del usuario |
| 2 | El modelo hidratado sin ruta | Candil, `Config.Hydrate` | el `--model nil` en el log |
| 3 | El modelo hidratado con un engine de mentira | Candil, `Engine` | el log, `port => 8080` |
| 4 | `--detach` decía "detached" sin nada detrás | Candil, `EnginePool` | `candil stop` que no paraba |
| 5 | `STATE` decía ON con el motor muerto | Candil, `CLI/Lifecycle` | **`ropero status`** |
| 6 | `--cpu` no hacía nada | Candil, el flag entero | el OOM de `llama-server` |
| 7 | **`--spec-ngram-n-min` no existe** | **el `candil.toml`** | el script de ropero |

---

## 1. `candil run` no arrancaba un modelo. Nunca.

`EnginePool.put/5` **parece arrancar y no arranca**: su `handle_call` guarda un
mapa en el estado del pool y contesta `:ok`. La función que levanta de verdad
el `Candil.Engine.Server` es `Engine.start/2`, y solo la llamaban
`Engine.Launcher` y `Candil.LLM`. **La CLI no.**

```
$ candil run coder
  coder arrancado en :9999
[exit=0]
```

Y no había modelo: ni proceso, ni VRAM, ni log del engine, ni crash report.
Porque no había nada que casara, nada que muriera y nada que imprimiera. La
función que anunciaba el arranque estaba bien escrita, y era verdad a su manera:
había un slot.

**Por qué no lo vio nadie:** todos los smokes de la fase mireban exit codes, y
`candil run` sale 0 haya modelo o no. Un código de salida no comprueba que algo
funcione; comprueba que el proceso terminó.

## 2. El modelo se hidrataba sin ruta

`model_dir` y `filename` —que son lo que se une para construir `--model`— se
leían **solo** de claves `model_dir` y `filename` dentro de `[model.X]`. Unas
claves que ningún toml escrito por una persona tiene: el formato documentado
pone el fichero en `[model.X.source]` como `file` y `dest`.

Así que el modelo se hidrataba con `model_dir: nil, filename: nil`, y
`build_args` hacía `Path.join(nil, nil)`, que tumba el GenServer en su `init/1`.

Lo confuso era que **todo lo demás sí leía la fuente**:

```
candil models info   ->  /home/lorenzo/models/gguf/Qwen3.8-27B-UD-Q3_K_XL.gguf
candil doctor        ->  sources 6/6 descargados
candil run analyst   ->  analyst arrancado en :9999
(btop)               ->  47 MB
```

Una pantalla que dice una cosa, un doctor que dice que está todo descargado, y
un arranque que no arranca. Tres fuentes de verdad y ninguna cruzada con la que
de verdad se lanza.

## 3. El engine era una cáscara

Tres sitios construían `%Engine{alias: model.engine}` — un struct con el alias
y **nada más**: sin `binary`, sin `install`, sin `api_key`, sin `start_args`, y
con `port: 8080`, que es lo que dice el defstruct. Dos de ellos lo usaban para
arrancar el modelo.

`EnginePool.put` contestaba `:ok` sin hacer nada, y el mensaje de arranque
hablaba del **slot**, no del engine. Verdad a su manera, engañoso en la que
importa.

## 4. `--detach` sin nada detrás

`record/3` escribía el claim con el pid del **propio escript**, que salía acto
seguido. `started/3` con `--detach` no hacía nada más que imprimir ese mismo pid.
El engine se arrancaba como hijo del VM lanzador, así que se iba con él.

No es intermitente: es imposible que funcione, en cada ejecución, siempre. Tres
mentiras en una línea —un proceso que no está, un log que no se crea, y un
`healthy: true` para un pid muerto— y todo con **código 0**.

`--detach` no era detach. Era *arrancar, anunciar y morir*.

Y dos bugs más detrás, ambos míos: el `id` de Arrea llevaba el **alias del
engine** en vez del modelo (el log del motor se llamaba `llama_cpp-9990.log`
mientras el titular anunciaba `analyst-9990.log`), y después llevaba
`Model.port` en vez de `engine.port` (que se desincronizan con `--port N`).
Con `coder` coincidían los dos y no se veían. **Un id repetido a mano es un id
que se desincroniza.**

## 5. `STATE` decía ON con el motor muerto

El registro guarda `healthy: true` del momento del arranque, y **nunca se vuelve
a comprobar**. La columna STATE respondía a "¿existe el proceso titular?", que
es necesario y no suficiente; mientras que en una tabla de modelos significa
"¿está sirviendo?".

Lo vio `ropero status`, no Candil:

```
[✓] analyst detached
candil status  ->  ON
ropero status  ->  :9999 OFF, GPU 47 MB
```

Los dos tenían razón sobre preguntas distintas, y solo uno contestaba a la que
dice la columna. Ahora `STATE` se pregunta: un `:gen_tcp.connect` al host y
puerto del registro, 500 ms, en paralelo.

## 6. `--cpu` no hacía nada

Se parseaba, se validaba, salía en el help, y **no se leía en ningún sitio**.
El modelo se lanzaba con sus `model_args` intactos, GPU incluido:

```
failed to fit params to free device memory:
  n_gpu_layers already set by user to 99, abort
allocating 12005.90 MiB on device 0: cudaMalloc failed: out of memory
```

Candil decía "esto va a CPU" mientras el modelo intentaba subir 12 GB a una
GPU que ya tenía 14 GB cogidos.

**Cuatro versiones del arreglo, las cuatro mal.** La primera quitaba
interruptores y flags de GPU de una lista de strings; la segunda arreglaba el
orden; la tercera tenía un bucle infinito; la cuarta rotaba el argv. Todas por
lo mismo:

> **Un argv no es una lista de parejas.** `--no-kv-offload` es un elemento y
> `--cache-type-k q8_0` son dos, y nada en la lista lo dice. Re-escribirlo
> exige una tabla de qué flags de llama.cpp llevan valor, y esa tabla no está
> en ninguna parte.

La solución fue la que el usuario propuso y la que ropero tenía escrita desde
el principio: **`--n-gpu-layers` es un campo**, como `context_size`. Un campo se
manipula como un campo, no hay argv que reescribir, y `Hydrate` saca el flag de
`model_args` **siempre**, para que no haya dos sitios para el mismo número.

## 7. El que de verdad era

`verifier` viene de `gptoss_high.sh` y `designer` de `gptoss_medium.sh`. Los
tres niveles de gpt-oss viven en un script común, `ropero.d/_gptoss_common.sh`:

| nivel | size-n | size-m | flag de rango |
|---|---|---|---|
| low | 6 | 16 | `--spec-draft-n-min/max` |
| medium | **12** | **48** | `--spec-draft-n-min/max` |
| high | **8** | **32** | `--spec-draft-n-min/max` |

Los dos modelos translationados tenían los números de `low` —6, 16, 1, 2— y un
flag **inventado**: `--spec-ngram-n-min`, donde ropero escribe
`--spec-draft-n-min`.

`llama-server` ve un argumento que no reconoce y sale con 1 **sin decir cuál**.
Y el síntoma —VRAM quieta, exit 1— es exactamente el de "no cabe en la
tarjeta", que es donde se estuvo horas buscando el bug.

**Un flag inventado se parece a un problema de memoria.**

---

## Lo que costó tiempo, en una frase

Toda la tarde se miró el código de Candil buscando un error que estaba en un
fichero de configuración, y ese fichero llevaba en su cabecera un aviso de que
era una traducción a mano de unos scripts que estaban a un `cat` de distancia.

Lo que faltaba no era el aviso —ya estaba— sino **la tabla que dijera qué
script es la fuente de qué modelo**, y que en el de gpt-oss los tres niveles
están juntos. Esa tabla está ahora en la cabecera del `candil.toml`.

---

## Los patrones, para que la próxima vez se píllen antes

1. **Probar la unidad y suponer el camino.** Ocho tests sobre la función que
   reescribía los argumentos, y ninguno sobre si el flag llegaba a ella. El
   patrón se repitió tres veces ese día, incluida `EnginePool.put/5`: una
   función correcta y un cableado que no la llamaba. El test que lo cazaba
   arranca el proceso de verdad y lee lo que recibió.

2. **Un exit code no es una comprobación.** `candil run` salía 0 sin arrancar
   nada, y todos los smokes del día comprobaban exit codes. Desde hoy el smoke
   del arranque mira **VRAM y puerto**, no el código.

3. **Un valor escondido en una lista de strings no se puede manipular.** Por eso
   `--n-gpu-layers` es un campo y no un flag suelto.

4. **"No hay instancias" y "no hay ninguna fuente de verdad" son lo mismo que
   "no lo sé".** Cuando dos herramientas dicen cosas distintas, la respuesta
   correcta es leer la fuente de una de las dos, no promediarlas.

5. **Un `candil.toml` es una traducción, y una traducción se verifica contra su
   original.** Se avisaba en la cabecera; faltaba el original al lado.

---

## Lo que sigue abierto

- **`ropero` y Candil gestionan los mismos puertos.** Ahora los dos saben lo
  mismo y dicen lo mismo, pero en cuanto haya tres modelos esa es una fuente
  de verdad que no es una. La respuesta de una sesión sería que ropero consultase
  a Candil, o al revés, no que los dos escriban.
- **El PR de Arrea.** `LongRunning.stop/1` devuelve `:ok` sin matar el proceso
  del SO: cerrar un puerto no mata un proceso, y `terminate/2` no llegaba a
  ejecutarse porque el GenServer no atrapaba salidas. Rama
  `fix/long-running-stops-the-os-process`, pendiente de PR. En cuanto entre,
  `mix deps.update arrea` y `Candil.CLI.HolderShutdownTest` se pone verde — es
  el único test que falla a propósito ahora mismo.
- **El smoke debería medir la GPU, no el exit code.** Es lo que habría
  encontrado el bug 1 en el minuto uno.
