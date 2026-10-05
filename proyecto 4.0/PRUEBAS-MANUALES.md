# Pruebas manuales — qué correr y qué tiene que pasar

> Este es el documento que se busca cuando `mix test` está en verde y aun así
> hay un bug. La lección de `candil` es repetida y no pleasant: una suite de
> 700 tests que nunca construye el binario deja pasar un `candil doctor` que
> imprimía un informe lleno de fallos **y salía con 0**.

## 0. Antes de nada: tener algo que probar

La mayoría de las pruebas de la fase 3 necesitan un modelo. Sin configuración,
`candil models list` responde `no models configured. Check candil.toml` y no
hay nada que arrancar.

Hay una configuración de ejemplo en el repo, **`proyecto 4.0/candil.toml`**, con
siete modelos ya declarados (`coder`, `analyst`, `verifier`, `designer`,
`coder_lite`, `embed`, `gpt4o`). Para usarla, lo normal es copiarla a donde
Candil la busca **por defecto**:

```bash
mkdir -p ~/.config/candil
cp "proyecto 4.0/candil.toml" ~/.config/candil/candil.toml
candil models list
```

Candil lee `~/.config/candil/candil.toml` sin que hagas nada. El `export` es
un atajo, no un requisito, y solo hace falta si no quieres tocar tu
configuración real:

```bash
export CANDIL_CONFIG="$PWD/proyecto 4.0/candil.toml"   # solo esta sesión
```

**El alias que pruebes tiene que existir en ese fichero.** `gptoss_medium` no
está; `coder` sí. Si tu configuración real tiene otros alias, usa los tuyos.

### Si `models list` dice `no models configured`

Casi siempre es que no hay configuración, o que la que hay **no parsea**. La
diferencia se ve en `doctor`, y por eso conviene mirarlo primero:

- `config` en `ok` → el fichero existe y se lee, pero no declara modelos.
- `config` en `error` con `invalid_toml` → hay una línea rota. El mensaje dice
  fichero, línea, columna y el trozo culpable; ábrelo por ahí.

Y si tocaste el ejemplo para ajustarlo a tu hardware —los `cmake_args` de la
sección `[engine.llama_cpp.install]`—, asegúrate de que sigue siendo TOML
válido: una cadena partida a mitad de línea da un error que parece de otra
cosa. Para volver al de fábrica:

```bash
git checkout -- "proyecto 4.0/candil.toml"
```

`candil models list` debe dar 7 filas, y las de tipo `local` saldrán como
`missing` en la columna `state`: el fichero GGUF no está descargado todavía, y
eso es lo correcto. Para descargarlo:

```bash
candil models pull coder      # descarga; el tamaño sale de la barra de progreso
candil models list            # ahora `coder` debería decir `downloaded`
```

---

## 1. El binario y el help

```bash
mix escript.build          # si no, estás probando un binario viejo
candil --help
candil help
candil version ; candil -v ; candil --version
candil run --help
candil doctor --help
```

**Esperado**

| Comando | Qué tiene que pasar |
|---|---|
| `candil --help` | tabla con los 7 comandos y `Run 'candil <command> --help'…` |
| `candil help`, `-h` | salida **idéntica** a `--help` |
| `version`, `-v`, `--version` | los tres dicen `Candil 4.0.0` |
| `candil run --help` | aparecen `--detach`, `--port`, `--force`, `--cpu`, `--yes` |

Lo de los flags importa porque **no salían antes**: el parser los aceptaba
desde hacía tiempo y el help no los mencionaba. Si vuelven a desaparecer, el
parseo y la descripción han vuelto a ser dos objetos distintos.

**Conocido y de Alaja, no de Candil:** `candil models list --help` imprime el
help y **después ejecuta el comando**, y en un TTY lo abre en modo pestañas con
el título *Alaja CLI* en lugar del de Candil. El título correcto es el de
Candil, y la fuga es real: quien tenga un TTY ve el help de la otra librería.

---

## 2. doctor

```bash
candil doctor ; echo "exit=$?"
candil doctor --json | jq -r '.[] | "\(.level)  \(.name)"' ; echo "exit=$?"
candil doctor --fix
candil doctor
```

**Esperado**

- 8 checks, siempre en este orden: `config`, `binary`, `sources`, `ports`,
  `auth`, `gpu`, `memory`, `disk`.
- `--json` da una **lista** de 8 objetos, no un objeto con `checks` dentro —
  para eso es `jq '.[0].name'` y no `jq '.checks[0].name'`.
- `--json` sale **sin escapes ANSI**. Si hay que comprobarlo:
  `candil doctor --json | grep -c $'\033'` tiene que dar `0`.
- `echo "exit=$?"` después de `doctor` es la prueba que más ha valido la pena:
  **si algún check está en `error`, el exit tiene que ser 1**. Un `doctor` que
  imprimía errores y salía con 0 dejaba a un CI en verde sobre una máquina
  rota.
- `--fix` crea `data_dir` y `log_dir`, y el mensaje dice **dónde escribió de
  verdad**, no dónde debería. Sale del propio `Instances.log_dir()`, que puede
  estar apuntado a cualquier sitio de `candil.toml`.

Con la configuración de ejemplo y sin binario construido, lo normal es que
`binary` y `sources` fallen — y entonces el exit **1** es lo correcto.

---

## 3. Arrancar y parar de verdad

```bash
candil status
candil run <alias>                    # en primer plano; Ctrl-C para salir
candil status
candil stop

candil run <alias> --detach ; echo "exit=$?"
candil status                         # aquí tiene que aparecer el engine
candil stop
```

**Esperado**

- `status` sin nada corriendo: `no hay instancias`.
- `run` levanta el engine, responde en su puerto, y `status` lo lista.
- `stop` lo para y `status` vuelve a `no hay instancias`.
- Con `--detach`, el engine sobrevive a la salida del comando y `status` lo ve
  desde otro proceso.

Este camino **no se ha ejercido nunca en el sitio donde se escribió**: sin GPU,
sin binario y sin modelos. Si algo falla aquí, es la parte que más conviene
mirar.

Antes de arrancar un modelo grande: `candil doctor` dice si hay memoria. Y
`run` comprueba preflight antes de registrar nada, así que un refusal es
correcto si el doctor ya avisaba.

---

## 4. Códigos de salida

```bash
candil frobnicate    ; echo "exit=$?"   # 1
candil run           ; echo "exit=$?"   # 1 — falta el modelo
candil doctor --nada ; echo "exit=$?"   # 1 — flag que no existe
candil version       ; echo "exit=$?"   # 0
candil status        ; echo "exit=$?"   # 0
```

El escript fija su código **haltando** con él; devolver un entero desde
`main/1` no hace nada, porque el envoltorio generado hace `halt(0)` al salir.
Ese detalle costó una tarde entera: `doctor` salía 0 y `run` salía 1, y la
diferencia era que el segundo lo haltaba el propio DSL por su cuenta.

---

## 5. El script

```bash
./scripts/manual-check.sh              # las cuatro fases
./scripts/manual-check.sh 2            # solo doctor
CANDIL=./candil ./scripts/manual-check.sh
MODEL=coder ./scripts/manual-check.sh 3   # fuerza el modelo de la fase 3
```

No se para en el primer fallo, registra el exit de cada comando y resume al
final. Pega el **RESUMEN** entero, y la fase concreta con su `exit=$?` si algo
falla.

---

## Cuando algo falla

Tres preguntas antes de culpar a una librería:

1. **¿El binario es el que crees?** `mix escript.build` sin ver la salida puede
   estar fallando y dejando el binario viejo. El escript ya **no está en el
   repo** por eso: un binario obsoleto commiteado es indistinguible de uno
   recién construido.
2. **¿El clone tiene todo?** `git status` limpio y `git ls-files lib | wc -l`
   con un número parecido al de `main`. Una vez cuatro módulos nuevos no
   llegaron al remoto por un patrón de `.gitignore` sin anclar, y la rama no
   compilaba. Nada falla en local: el `git add -A` dice que ha ido bien.
3. **¿El mensaje es de Candil o del hermano?** Los dos fallos conocidos que
   quedan son de Alaja y se distinguen por el texto: *Alaja CLI* en el título,
   y `command 'models' has no handler defined`.

---

## Los fallos de arranque que ya están ARREGLADOS (2026-10-05)

Si algo de esta tabla te pasa, **no lo busques en Candil: ya está arreglado**
y lo que ves es un binario viejo. Se comprueba con `grep` sobre el binario, no por la fecha.

| Síntoma | Qué era | Desde |
|---|---|---|
| `candil run X` dice "arrancado" y no arranca nada | `EnginePool.put` no arrancaba nada; la CLI nunca llamó a `Engine.start` | `b64413f` |
| El engine se lanza contra el puerto 8080 y sin binario | tres sitios montaban un `%Engine{}` vacío | `b64413f` |
| `--detach` dice "detached" y `stop` no para nada | el claim lo escribía el proceso que se iba a morir | `b64413f`, `edaa7aa` |
| `candil status` dice ON con el motor muerto | `STATE` releía un `healthy` del arranque y nunca lo volvía a preguntar | `4e85268` |
| `candil status` no ve una instancia detached | leía solo la memoria del VM, y `stop` leía las dos | `4e85268` |
| `--cpu` no hace nada | el flag se parseaba y no se leía en ningún sitio | `db0e726` |
| `llama-server` sale con 1 y el log está vacío | `Arrea.LongRunning.stop/1` no mata el proceso del SO | **PR de Arrea** |

**Si ves `--n-gpu-layers 99` después de poner `--cpu`**, tu binario es viejo:

```bash
ls -la candil ~/.local/bin/candil      # mismo tamaño y fecha
sudo cp candil ~/.local/bin/candil
candil run analyst --detach --port 9998
grep 'capas' ~/.candil/logs/analyst-9998.log
```

Esa línea tiene que decir `99 capas a la GPU → 0`. Si no aparece, no tienes
el binario nuevo.

**Si `llama-server` sale con 1 y el log solo tiene el crash report de Candil**,
mira los flags del modelo: un argumento que `llama-server` no reconoce sale
con 1 **sin decir cuál**. Pasa el comando a mano y te contesta.

Todo esto, con la causa de cada uno, está en
`auditoria/2026-10-05-bugs-de-arranque.md`.

