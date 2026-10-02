# Candil 4.0 — guía del proyecto

> Este directorio es el mapa. Si acabas de abrir una sesión nueva y no sabes por
> dónde empezar, empieza por aquí, y luego por el README de la fase siguiente.

## Qué se está construyendo

**Candil 4.0** es un **router de modelos de lenguaje**: recibe una petición
(openai‑compatible, MCP, o desde la CLI), decide qué modelo la responde, y
devuelve la respuesta. Todo local, con los modelos corriendo en tu máquina.

El problema que resuelve: hoy cada consumidor —posadero, gunter, opencode— tiene
su propia lógica para elegir modelo, y esa lógica está desparramada. Candil la
centraliza, la hace configurable en un TOML, y la hace comprobable con
`candil doctor`.

La forma final: los consumidores hablan con un **gateway OpenAI‑compatible**, no
con modelos. Se les cambia un `base_url` y todos caterpillarizan por el mismo
sitio.

## Por qué los ficheros están donde están

```
proyecto 4.0/
├── README.md              ← ESTE FICHERO. El mapa.
├── HANDOFF.md             ← documento vivo. Qué se decidió y por qué.
├── candil.toml            ← la configuración real, 7 modelos de ropero
│
├── fases/                 ← un documento por fase. LO QUE VAS A IMPLEMENTAR
│   ├── fase-2-README.md
│   ├── fase-3-README.md
│   ├── fase-5-README.md
│   ├── fase-6-README.md
│   ├── fase-7-README.md
│   ├── fase-8-README.md
│   ├── fase-9-README.md
│   ├── fase-10-README.md
│   ├── fase-11-README.md
│   ├── PLAN-VENTANA-PARALELA.md
│   └── PROMPT-VENTANA-PARALELA.md
│
└── original/              ← el diseño. NO LO MODIFIQUES, no es tuyo
    ├── candil-4.0-final.md    ← EL DISEÑO. 3.000 líneas, es la fuente
    ├── version 1.md           ← lo que había antes de decidir
    ├── version 2.md
    ├── version 3.md
    ├── PLAN-PARALELO.md
    ├── PROMPT-INTEGRAR-FASE-2.md
    └── snapshot.sh
```

## Cómo se interpretan

Es lo importante, porque los dos directorios no valen lo mismo.

| | `fases/` | `original/` |
|---|---|---|
| Quién lo escribió | las sesiones de trabajo | tú, antes de empezar |
| Qué es | **instrucciones de implementación** | **el diseño** |
| Se lee | entero, de arriba abajo | por secciones, buscando |
| Se actualiza | sí, cuando la fase avance | **no** |
| Se contradice | gana `fases/` | pierde contra `fases/` |

**Si `fases/` y `original/` se contradicen, `fases/` tiene razón**, porque
`original/` se escribió antes de que nadie hubiera tratado con la API real de
ropero, ni con las trampas del entorno. Los docs de fase existen *por* eso.

### Cómo leer el diseño sin perderte

`original/candil-4.0-final.md` tiene 3.000 líneas. **No lo leas entero.**

1. `grep -n '^## '` para el índice.
2. `grep -n 'Fase N'` para la fase que te toca.
3. Lee **solo** esa fase y las secciones `§` a las que remite.

Ese error ya se cometió una vez: leer el diseño entero cuesta una hora y no
mejora el resultado.

## Qué está hecho

| Fase | Qué era | Estado |
|---|---|---|
| −1 | Esqueletos: 48 ficheros, headers, TODOs | ✅ integrada |
| 0 | Cimientos, Store, config, errores | ✅ integrada |
| 1 | Fuentes, HTTP, checksum, `.complete` | ✅ integrada |
| 2 | Build, descarga, `EnginePool`, `candil.toml` | ✅ integrada |
| 3 | CLI, `Config.Hydrate` | ✅ integrada |
| 4 | Instancias, `--detach`, `stop`, `status` | ✅ integrada |
| 5 | **Doctor**, `--fix`, `--json`, precios a `priv/` | ✅ integrada |
| 6 | Context compartido | 📄 doc listo, sin código |
| 7 | Router | 📄 doc listo, sin código |
| 8 | Gateway OpenAI‑compatible | 📄 doc listo, sin código |
| 9 | MCP servidor y cliente | 📄 doc listo, sin código |
| 10 | RAG | 📄 doc listo, sin código |
| 11 | Consumidores, docs, `4.0.0` | 📄 doc listo, sin código |

**Estado medido ahora**: 702 tests + 26 doctests, 0 fallos, 66.0% de cobertura,
los ocho gates verdes. Rama de desarrollo: **`4.0`**.

## Cuál hacer ahora

**La 6.** Es la siguiente de la ruta crítica y la única cuyo contenido
depende solo de la 4.

```bash
cd /workspace/repos/candil
. /workspace/tools/env.sh
git fetch origin
git checkout -b 4.0-f6-context origin/4.0
```

Léete `fases/fase-6-README.md` entero antes de escribir código.

## Cómo se usa esta documentación

**Para una sesión nueva que implementa una fase:**

1. `fases/README.md` ← este fichero, para el contexto
2. `fases/fase-N-README.md` ← entero
3. `HANDOFF.md` §2, para el estado medido
4. `original/candil-4.0-final.md` **solo** la sección de esa fase

Cada doc de fase tiene la misma forma: qué es · por qué aquí · por qué no ·
dónde · qué hacer · cómo se comprueba · qué **no** hacer · definición de done.

**Para una sesión nueva que revisa algo:**

1. El `fase-N-README.md` correspondiente
2. `HANDOFF.md`, que tiene el porqué de todo
3. Los ocho gates, que son la ley

## Los ocho gates

Ningún cambio se da por bueno sin los ocho:

```bash
mix format --check-formatted
mix compile --force --warnings-as-errors
mix credo --strict --format=oneline
mix test --cover
mix dialyzer
mix docs --warnings-as-errors
mix hex.audit
mix deps.unlock --check-unused
```

## Reglas que no se rompen

1. **La rama es `4.0`, y las fases van en `4.0-fN-algo`.** Con guion.
   `4.0/f6-context` es **imposible**: Git no admite un ref y un directorio en
   el mismo sitio.
2. **PR contra `4.0`, nunca push directo.** Ni a `4.0` ni a `main`.
3. **Nunca `git push --force`** en trabajo normal.
4. **`mix.exs` solo lo toca el carril H**, y el cambio se pide en el PR.
5. **Los tests que tocan disco usan `CANDIL_DATA_DIR=<tmp>`.**
6. **`mix deps.get` necesita el mirror**:
   `python3 /workspace/tools/hex_mirror.py --port 4000`.
7. **No se inventa que algo funciona.** Si falta GPU, modelo, GGUF o CI, se dice
   que falta. Un hueco de entorno reportado vale más que un shim que parece
   funcionar.

## Si algo se pone raro

`HANDOFF.md` §Trampas tiene la lista real, descoberta.:
`/opt` es efímero · `nohup` no sobrevive · `System.pid/0` cambia de tipo ·
`Process.alive?/1` es para pids Erlang, no de SO · `Enum.filter/2` no es un
mapper · `Map.update/4` es `(map, key, default, fun)` · `mix format` puede
reexpandir `Enum.map_join` · este Elixir rechaza `"k" => v` dentro de `[...]`.

**Empieza por `HANDOFF.md`.** Es el documento que lleva el porqué de cada fase
desde la 0. Si algo de lo que hay aquí contradice lo que encuentras al medir,
manda lo medido, y se arregla el doc.
