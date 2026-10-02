# Continuación de la fase 2 de Candil 4.0 — rebasear y mergear

## Contexto

Hay dos líneas de trabajo paralelas sobre este repositorio, y la tuya ya
terminó. Ahora toca integrarlas.

**Lo que hiciste tú** (rama `4.0-f2-build`, PR #18 abierto):
las tres piezas de la fase 2, completas y con el CI en verde.

**Lo que hizo la otra sesión** mientras tanto (ya en `main`):
las fases **0** y **1** del plan, más el congelado de contratos de la −1.

Ambas tocaron el mismo repositorio y hay un punto de fricción real.
Nada está roto; simplemente hay que integrar.

════════════════════════════════════════════════════════════════════════
1. ESTADO ACTUAL
════════════════════════════════════════════════════════════════════════

```
main           28f09ecb   ← todomerged: contratos (-1), gates (-0),
                              los ocho bugs (0), Source y TOML (1)
 4.0            4b9ce5d6   ← lo mismo, con los commits sin aplastar
 4.0-f2-build   9ad0f7a1   ← TU rama,基于 en un 4.0 más antiguo
```

Tu rama nació de `4.0` antes de que llegaran las fases 0 y 1. Por eso el
PR #18 probablemente dé conflictos.

════════════════════════════════════════════════════════════════════════
2. EL CONFLICTO QUE TE VA A SALIR, Y CÓMO RESOLVERLO
════════════════════════════════════════════════════════════════════════

### `lib/candil/engine_pool.ex` — el importante

Tú lo reescribiste como registro de instancias con `claim_port/2`.
La otra sesión **no tocó EnginePool** en las fases 0 y 1.

**Tu versión gana, entera.** No mezcles: es tu reescritura, y
`claim_port/2` es la razón por la que la fase 2 existe.

Si Git te propone "mantener los dos lados", quédate con **el tuyo**.

### `lib/candil/engine.ex`

Tú le añadiste 22 líneas. La otra sesión le añadió `api_key`,
`auth_headers/1`, `auth_headers_for/1`, `base_url_and_headers/2` y
`validate/1`, que son **la corrección de H1** (el bug que bloqueaba
absorber ropero).

Aquí **las dos partes se necesitan**. Si Git te da conflicto:
conserva *todo* lo suyo (los cinco métodos nuevos) y además lo tuyo.
Lo tuyo eralittle más que el nuevo `binary`, `base_port` e `install`.

### `CHANGELOG.md` y `lib/candil/installer.ex`

Conflicto de texto, no de código. En el CHANGELOG: **una** entrada de
cada fase, en orden (−1, −0, 0, 1, 2). No tres copias de la misma.

En `installer.ex`: theirs es el checksum **en streaming** (B8, que leía
17 GB de golpe con `File.read/1`); tuyo es lo otro. Mira el fichero y quédate
con lo que esté bien — probablemente theirs en esa función concreta.

════════════════════════════════════════════════════════════════════════
3. CÓMO HACERLO
════════════════════════════════════════════════════════════════════════

```bash
cd ~/cacafuti/candil
git fetch origin
git checkout 4.0-f2-build

# trae main, que ya tiene las fases 0 y 1
git merge origin/main

# resolver los conflictos leyendo el CHANGELOG de main, no el del squash
git show origin/main:CHANGELOG.md | head -60

git add -A
git commit          # "merge(main): fases 0 y 1, con EnginePool de la fase 2"
git push origin 4.0-f2-build
```

**Sin `git push --force` y sin `git rebase`.** Un merge es auditable;
un rebase reescribe historia en una rama que otra sesión ya empujó.

Si el merge sale *limpio* sin conflictos, más fácil: significa que ya
lo habías hecho y solo había que empujar. Comprueba con
`git log --oneline origin/main..HEAD` que están tus commits de fase 2.

════════════════════════════════════════════════════════════════════════
4. LOS OCHO GATES — ANTES DE MERGEAR
════════════════════════════════════════════════════════════════════════

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

Referencia: en `main` hay **549 tests, 0 fallos, 64.6 % de cobertura**,
y los ocho gates en verde. Si al integrar te baja de 549 o sube el
número de fallos, el conflicto se resolvió mal: vuelve atrás.

Y mira el CI del PR **antes** de pedir el merge. Esta vez un job salió
rojo porque se mergeó sin mirar, y hubo que abrir un PR aparte para
arreglarlo.

════════════════════════════════════════════════════════════════════════
5. LO QUE CAMBIA PARA TU TRABAJO
════════════════════════════════════════════════════════════════════════

Nada de lo que hiciste queda obsoleto, pero hay tres cosas nuevas que
afectan a la fase 3:

**H1 ya está resuelto.** `Engine.auth_headers_for/1` existe y los tres
call sites de la ruta local ya lo usan; `Engine.Server` emite `--api-key`.
Esto **no cambia tu `Build.install/2` ni tu `EnginePool`**, pero sí
significa que la prueba de aceptación de la fase 0 (un `llama-server`
real con `--api-key`, y el mismo test sin key esperando 401) ya debería
pasar. Si no la has hecho, es un buen momento: es la prueba que decide
si la absorción de ropero es viable.

**`Source.fetch/2` existe.** Si tu `candil.toml` declaring sources, ya
se descargan. `Source.progress/1` da los bytes escritos para una barra.

**`Config.File.save/2` existe.** Si algo necesita escribir la config,
ya no hay que hacerlo a mano.

════════════════════════════════════════════════════════════════════════
6. DOCUMENTOS

Al integrar, `proyecto 4.0/HANDOFF.md` queda desactualizado por la parte
de las fases 0 y 1. Actualiza §2 (qué se hizo) y §3 (qué sigue) con
números **medidos del output real**, no de memoria.

Y recuerda que ya escribiste `PROMPT-FASE-3.md` para la siguiente fase:
revísalo contra el estado merged, porque ahora hay stubs menos de los
que había cuando lo escribiste.
