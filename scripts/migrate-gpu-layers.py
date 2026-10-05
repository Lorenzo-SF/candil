#!/usr/bin/env python3
"""Saca `--n-gpu-layers` de `model_args` y ponlo como campo `gpu_layers`.

    python3 scripts/migrate-gpu-layers.py ~/.config/candil/candil.toml

## Por que

Con el flag escondido dentro de `model_args` hay DOS sitios para el mismo
numero. Candil cree que manda el campo y llama-server se queda con el flag,
y el error que sale —"n_gpu_layers already set by user"— no dice de donde sale
el numero. Por eso `--cpu` no podia apagarlo sin reescribir un argv entero, que
exige saber que flags llevan valor, cosa que no se sabe.

No tienes que hacerlo para que funcione: `Hydrate` ya lee el flag de
`model_args` y lo pasa al campo. Esto es para que el fichero DIGA lo que hace,
que es distinto de que lo haga.

## Que NO toca

`--n-gpu-layers-draft` es OTRO flag —el del modelo de especificación— y se
queda donde está. Y todo lo demás se queda igual: el script solo quita el flag
del modelo y añade una línea.

## Seguridad

Copia antes de escribir, y si el resultado no parsea como TOML, no escribe
nada: un `candil.toml` que no carga es peor que uno con el flag dentro.
"""
import re
import shutil
import sys
import datetime
import tomllib
import pathlib

MODEL = re.compile(r"^\s*\[model\.([^\]]+)\]")
ANY = re.compile(r"^\s*\[")
MID = re.compile(r',\s*"--n-gpu-layers"\s*,\s*"?(-?\d+)"?')
FIRST = re.compile(r'"?--n-gpu-layers"?\s*,\s*"?(-?\d+)"?\s*,\s*')


def main(path_str: str) -> int:
    path = pathlib.Path(path_str)
    original = path.read_text()

    lines = original.splitlines(keepends=True)
    out, moved, i = [], [], 0

    while i < len(lines):
        if not MODEL.match(lines[i]):
            out.append(lines[i])
            i += 1
            continue

        j, block = i + 1, []
        while j < len(lines) and not ANY.match(lines[j]):
            block.append(lines[j])
            j += 1

        body = "".join(block)
        out.append(lines[i])
        hit = MID.search(body) or FIRST.search(body)

        if hit:
            out.append(f"gpu_layers   = {hit.group(1)}\n")
            body = (MID.sub("", body, 1) if MID.search(body) else FIRST.sub("", body, 1))
            body = re.sub(r"\[\s*,", "[", body).replace(",,", ",")
            body = re.sub(r",(\s*[\]\}])", r"\1", body)
            moved.append(MODEL.match(lines[i]).group(1))

        out.append(body)
        i = j

    candidate = "".join(out)

    try:
        tomllib.loads(candidate)
    except tomllib.TOMLDecodeError as err:
        print(f"el resultado NO parsea, no se escribe nada:\n  {err}", file=sys.stderr)
        return 1

    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    backup = path.with_suffix(path.suffix + f".bak-{stamp}")
    shutil.copy2(path, backup)

    path.write_text(candidate)
    print(f"migrados: {len(moved)} ({', '.join(moved) or 'ninguno'})")
    print(f"copia:    {backup}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
