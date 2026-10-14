#!/usr/bin/env bash
# Abre los ocho PR de la pila, cada uno sobre el anterior.
set -euo pipefail
cd "$(dirname "$0")/.."

declare -A TITULOS=(
  [feat/reglas-desde-el-toml]="[router.rules] se lee del toml, por alias y en tu idioma"
  [feat/fallback-configurable]="El fallback tambien se configura: decide mas que las capas"
  [feat/forzar-capa-desde-gateway]="Forzar la capa desde la propia llamada al gateway"
  [fix/forzar-capa-corre-capa]="Forzar una capa, correr esa capa y solo esa"
  [chore/barrido-de-umbral]="chore: el barrido de umbral, que decide si hace falta un LLM"
  [feat/reglas-de-decision]="Reglas de decision con condicion y accion: force, prefer, veto"
  [fix/cache-clave-con-forzado]="La clave de la cache incluye el forzado"
  [fix/todos-vetados-y-traza]="Todos vetados es una decision imposible, y la traza en la Decision"
)

declare -A CUERPOS=(
  [feat/reglas-desde-el-toml]="La capa \`:rule\` era un \`@rules\` de modulo, en ingles, con las categorias mapeadas a tres alias fijos. \`config/template.ex\` decia que se configuran en \`[router.rules]\` y **nadie lo leia**: \`grep \"router.rules\" lib/\` daba cero.

Medido sobre 84 peticiones reales de los siete repos, en espanol: la capa disparo **cero veces**. El propio codigo lo avisaba.

Sin \`[router.rules]\` no cambia nada: *ausente tiene que ser inerte*, porque una capa que decide con reglas que nadie ha puesto es lo contrario de configurable. Hay un test que lo fija.

4.8% -> 11.9% de las peticiones resueltas por una capa, sin codigo y sin recompilar."
  [feat/fallback-configurable]="Con las reglas vivas, **74 de cada 84 peticiones caen al fallback**. Es la decision que mas veces se toma, y era una linea: \`List.last(candidates)\`.

El ultimo de la lista. No es round-robin, ni afinidad, ni «el menos usado». Un «coge el ultimo y ya» escrito como si fuera una politica.

Se elige desde el toml: \`[router] fallback = \"round_robin\"\`.

**No es un registro de modulos.** D-11 pregunta si \`Provider\` es un registro o una lista cerrada, y no esta contestada; abrir un registro nuevo antes de contestar eso es abrir la puerta sin saber que hay detras. Una lista cerrada de cuatro no cierra ninguna puerta.

Medido despues (\`scripts/…\`): las cuatro se diferencian en **un punto de 48**. Reparten distinto, pero repartir no es acertar mas."
  [feat/forzar-capa-desde-gateway]="La pieza ya existia —\`force_strategy\` esta en \`DecisionEngine\` desde antes— y **no se podia pedir desde fuera**.

Para un agente eso no sirve: quien quiere «esta va por reglas» no tiene forma de decirlo sin reconfigurar Candil entero.

    X-Candil-Strategy: rule                             <- cabecera
    {\"model\": \"auto\", \"candil\": {\"strategy\": \"rule\"}}    <- cuerpo

La cabecera es lo unico que se puede mandar sin que el cuerpo deje de ser un cuerpo OpenAI. Gana el cuerpo si vienen los dos. Y una capa que no existe es un **400**, no un silencio.

12 tests end-to-end con HTTP de verdad en los dos lados: un Bandit que hace de motor y otro de gateway."
  [fix/forzar-capa-corre-capa]="\`by_embeddings/5\` miraba \`forced_layer\` y \`by_rules/4\` **no**.

    forzando :rule      -> [:rule, :rule, :embedding]
    forzando :embedding -> [:embedding, :rule]

Forzar \`:rule\` ejecutaba las reglas **dos veces** —justo lo que el comentario de al lado dice que no queremos— y forzar \`:embedding\` dejaba entrar \`:rule\` igual.

No es un detalle de optimizacion: \`[:candil, :router, :decision]\` documenta que \`:layers_ran\` son las capas que **corrieron**, y si documenta otra cosa el tribunal mide un motor que no es el que hay."
  [chore/barrido-de-umbral]="Script de medicion, sin cambios de comportamiento.

106 peticiones en cuatro idiomas, barriendo el umbral de similitud y mirando **resolucion y acierto a la vez**:

    umbral  resuelve  de esas, acierta  manos al LLM
    0.55      9/106      5/5  (100%)        97
    0.35     32/106     11/11  (100%)        74
    0.30     43/106     12/13  ( 92%)        63
    0.25     72/106     14/19  ( 74%)        34

**El listón de 0.55 venia de la escala de otro modelo de embeddings y nadie lo decidio.** A 0.35 se triplica lo resuelto sin perder ni un acierto.

Se sube como script y **no** cambiando el defecto: el cambio de defecto es una decision, y esta es."
  [feat/reglas-de-decision]="Traduccion de tres piezas de una especificacion externa que describe otro programa (su propio arbol de supervision, su \`routing.toml\`, sus \`Router.*\`). No se implementa como framework paralelo: meteria un segundo framework dentro del primero.

    [[router.decision]]
    reason = \"el posadero solo indexa; que no le llegue el chat\"
    when = { consumer = \"posadero\" }
    force = \"embed\"

**La separacion entre restriccion dura y preferencia** es la linea de D-09 —*«ninguna puede devolver un modelo vetado»*— puesta donde se puede comprobar: un \`prefer\` de diez puntos no resucita a un vetado.

**No se coge el bandit contextual**: la recompensa que proponia es \`0.4*quality + 0.3*latencia + 0.3*coste\`, y Candil **no sabe la calidad de una respuesta**. El 40% de la recompensa seria una constante y el bandit aprenderia «el mas barato», que no es enrutado."
  [fix/cache-clave-con-forzado]="\`cache\` se consulta **antes** que la capa forzada. Con una clave de \`{consumer, hash}\`, la entrada guardada de un \`auto\` se devuelve a una peticion que pide otra capa: se pide «esta va por reglas» y contesta la capa de siempre.

**No es un bug de orden; es de clave.** Y el arreglo no es saltarse la cache —la cache es la capa mas barata y saltarsela es pagar una decision ya tomada—. Es que son **dos entradas distintas de la misma peticion**.

El test de la gateway que documentaba el bug decia «queda sin verificar» porque \`last_layers()\` salia \`[:cache]\`. **Ha dejado de cumplirse.**"
  [fix/todos-vetados-y-traza]="**Todos vetados es una decision imposible, no una decision vetada.**

D-09 es binaria: o hay un superviviente, o no hay decision. Antes, si se vetaban los tres, se devolvia la decision tal cual apuntando al vetado. No lo habia visto nadie porque nadie ha vetado los tres a la vez.

Y de paso, **\`layers_ran\` en la \`Decision\`**, no solo en el evento. Nos costo tres horas descubrir que la cache se comia el forzado; con esto se ve en la primera peticion."
)

orden=(
  feat/reglas-desde-el-toml
  feat/fallback-configurable
  feat/forzar-capa-desde-gateway
  fix/forzar-capa-corre-capa
  chore/barrido-de-umbral
  feat/reglas-de-decision
  fix/cache-clave-con-forzado
  fix/todos-vetados-y-traza
)

base=main
for rama in "${orden[@]}"; do
  cuerpo="${CUERPOS[$rama]}"
  if [ "$base" != "main" ]; then
    cuerpo="$cuerpo

---
*Apilado sobre \`$base\`. Mergéalo antes que este.*"
  fi

  url=$(gh pr create --base "$base" --head "$rama" \
        --title "${TITULOS[$rama]}" --body "$cuerpo" 2>&1 | tail -1)
  echo "$rama -> $url"
  base="$rama"
done