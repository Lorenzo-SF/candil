# Integrar la fase 2 con main

> Copia el bloque de abajo en la sesión que hizo la fase 2. Verifica las
> referencias antes de usarlo: los SHAs cambian en cuanto alguien mergea otra
> cosa.
>
> Los números vienen de medir, no de suponer. `main` tenía **549 tests, 0
> fallos, 64.6 % de cobertura** y los ocho gates en verde; de los diez
> ficheros que tocó la fase 2, solo **tres** se habían movido en `main`.

---

Tu trabajo de la fase 2 está hecho y verificado. Ahora hay que integrarlo con
lo que otra sesión mergeó en `main` mientras tanto.

## Dónde está cada cosa

```
main           28f09ecb  contratos (-1), gates (-0), los ocho bugs (0),
                          Source y TOML (1)
 4.0            4b9ce5d6  lo mismo, con los commits sin aplastar
 4.0-f2-build   9ad0f7a1  TU rama, PR #18 abierto
```

**Ojo con el número de commits.** `git log origin/main..HEAD` te va a decir
29 commits, y solo **cuatro** son trabajo nuevo tuyo. El resto ya está en
`main`, pero como `main` los mergeó con squash, git no lo reconoce y los
lista igual. Los tuyos de verdad son:

```
70e0a2b  feat: build the engines, both strategies      (fase 2, parte 1)
45117d1  feat: EnginePool as a registry of instances   (fase 2, parte 2)
9d5d626  feat: ropero's config, translated by hand     (fase 2, parte 3)
6512df1  test: :source against a real cmake
```

Para ver el conflicto real, compara contra el ancestro común, no contra main:

```bash
git diff --stat $(git merge-base HEAD origin/main)..HEAD -- lib/ test/
```

## Los tres ficheros donde sí hay fricción

De los diez que tocaste, solo **tres** se han movido en `main` desde que
empezaste. El resto entra limpio.

### `lib/candil/engine_pool.ex` — tu versión gana, entera

Las fases 0 y 1 no lo tocaron. Es tu reescritura, y `claim_port/2` es
justo lo que la fase 2 vino a aportar. Si Git ofrece "mantener los dos
lados", quédate con **el tuyo** sin negociar.

### `lib/candil/engine.ex` — aquí hacen falta las dos cosas

Tú añadiste 22 líneas. La otra sesión añadió los cinco métodos de H1:

```
api_key/1  auth_headers/1  auth_headers_for/1
base_url_and_headers/2  validate/1
```

Esos cinco son **la corrección que desbloquea absorber ropero**. No se
pierden. Consérvalos todos y encima lo tuyo.

### `lib/candil/config/file.ex` — texto, no código

Tú tocaste 21 líneas y la otra sesión reescribió el escritor de TOML
(que antes de la fase 1 ni existía). Mira el fichero antes de decidir:
Lo suyo es lo que pasó los tests de round-trip, y probablemente es
lo que tiene que quedarse en `render/2` y `encode/1`. Tu cambio de 21 líneas era
sobre la versión anterior.

## Cómo integrarlo

```bash
cd ~/cacafuti/candil
git fetch origin
git checkout 4.0-f2-build
git merge origin/main
```

Resuelve los tres ficheros de arriba, y después:

```bash
git add -A
git commit -m "merge(main): fases 0 y 1, conservando EnginePool de la fase 2"
git push origin 4.0-f2-build
```

**Sin `git rebase` y sin `git push --force`.** Esta rama ya está
publicada y tiene un PR abierto; un merge deja rastro, un rebase borra el
historial que alguien puede estar leyendo.

Si el merge sale limpio, aún así comprueba que tus tres commits siguen
ahí antes de darlo por bueno:

```bash
git log --oneline $(git merge-base HEAD origin/main)..HEAD
```

## Los ocho gates, y la referencia

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

En `main` hay **549 tests, 0 fallos, 64.6 % de cobertura**, los ocho gates
verdes. Tú añadiste unos mil ochocientas líneas de tests, así que el número
deberá **subir**. Si baja de 549, o si aparecen fallos, el conflicto se
resolvió mal: vuelve atrás y reconsérvalo.

Y mira el CI del PR antes de pedir el merge. Esta vez se mergeó un PR con un
job en rojo porque nadie miró, y hubo que abrir otro PR para arreglarlo.

## Lo que hay ahora en main que no había cuando empezaste

**H1 está resuelto.** `Engine.auth_headers_for/1` existe, los tres call
sites de la ruta local de inferencia ya lo usan, y `Engine.Server` emite
`--api-key` y `--alias` en la línea de comandos. Eso **no cambia tu
`Build.install/2` ni tu `EnginePool`**, pero sí habilita la prueba de
aceptación que probablemente no pudiste hacer:

```bash
llama-server --model <un gguf> --port 39999 --api-key sk-test-key -fa on --embedding &
# Candil.embed(:algo, ["hola"]) debe devolver vectores
# y con la key quitada, 401
```

Es la prueba que decide si la absorción de ropero es viable. Si te sale
bien, es el dato más útil que puedes aportar.

**`Source.fetch/2` existe** y descarga con `.part`, reanudación por `Range` y
checksum en streaming. Si tu `candil.toml` declara sources, ya baja solo.
`Source.progress/1` da los bytes escritos para una barra de progreso.

**`Config.File.save/2` existe** y escribe atómico. Si algo necesita
volcar la config, ya no hay que hacerlo a mano.

## Documentos

`proyecto 4.0/HANDOFF.md` se quedó desfasado en la parte de las fases 0 y
1, y tu `PROMPT-FASE-3.md` se escribió cuando había más stubs de los que
hay ahora. Actualiza los dos con números **medidos del output real de los
comandos**, no de memoria.
