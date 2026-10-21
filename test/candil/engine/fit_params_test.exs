defmodule Candil.Engine.FitParamsTest do
  @moduledoc """
  El parser de la salida de `llama-fit-params`.

  Los dos fallos que estos tests fijan **solo se ven con la salida real**: un
  modelo que necesita recorte, porque es el único caso en el que `fit-params`
  escribe un `-ot` y en el que el peso ajustado es **menor** que el
  proyectado.

  La salida de abajo es la REAL, recortada a las líneas que importan. Es de
  `Qwen3-Coder-30B-A3B-Instruct-UD-IQ3_XXS` (12,8 GB) con contexto 131072,
  caché `q8_0` y 11518 MiB libres en la RTX 5080 (medido el 2026-10-21).

  ## Lo que dice esa salida, y por qué importa

  | Línea | Qué es |
  |---|---|
  | `\| - CUDA0 \| 15933 = 11518 + (10452 = 3479 + 6528 + 444) + -6037 \|` | El desglose: **15933** es el total que ve llama.cpp, **11518** el libre, y **10452** lo que ocupa el modelo (pesos 3479 + KV 6528 + compute 444) |
  | `projected to use … MiB` | Lo que haría falta **si todo el modelo cupiera en GPU**. No es lo que se ocupa |
  | `id=0, n_layer=49, …, mem= 10452 MiB` | **El peso ajustado**: lo que va a ocupar de verdad |
  | `-c 131072 -ngl 49 -ot "blk\\.11\\.ffn_down.*=CPU,…"` | Los args, con el `-ot` **entrecomillado** |

  Los dos fallos:

  1. Leer el `projected to use` en vez del `mem` da un peso **mayor** que la
     memoria libre, y la reserva se rechaza: el modelo que necesita recorte
     es justo el que no puede arrancar.
  2. Pasar el `-ot` con las comillas pegadas hace que llama-server responda
     `error while handling argument "-ot": unknown buffer type` y **no
     arranque**.
  """

  use ExUnit.Case, async: true

  alias Candil.Engine.FitParams

  # La salida real, recortada a lo que el parser mira.
  @real_output """
  0.04.163.422 D llama_graph_n_input_tensors: input tensor '                  attn_inp_k_rot' [f32, ne = {   128,   128,     1,     1 }] is used by node 'node_3387' (MUL_MAT)
  0.04.164.050 I sched_reserve: reserve took 10.64 ms, sched copies = 1
  0.04.164.421 I common_memory_breakdown_print: | memory breakdown [MiB]          | total    free     self   model   context   compute    unaccounted |
  0.04.164.423 I common_memory_breakdown_print: |   - CUDA0 (RTX 5080 Laptop GPU) | 15933 = 11518 + (10452 =  3479 +    6528 +     444) +       -6037 |
  0.04.164.423 I common_memory_breakdown_print: |   - Host                        |                   8912 =  8767 +       0 +     144                |
  0.04.191.100 I common_params_fit_impl: projected to use 19053 MiB of device memory vs. 11518 MiB of free device memory
  0.04.191.213 I common_params_fit_impl: memory for test allocation by device:
  0.04.191.221 I common_params_fit_impl: id=0, n_layer=49, n_part=38, overflow_type=3, mem= 10452 MiB
  0.04.191.225 I common_params_fit_impl: set ngl_per_device[0].(n_layer, n_part, overflow_type)=(49, 38, GATE), id_dense_start=0
  0.04.191.227 I common_params_fit_impl:   - CUDA0 (NVIDIA GeForce RTX 5080 Laptop GPU): 49 layers (38 overflowing),  10452 MiB used,   1066 MiB free
  0.04.191.231 I common_fit_params: successfully fit params to free device memory
  0.04.191.235 I common_fit_params: fitting params to free memory took 4.14 seconds
  0.04.191.236 I llama_fit_params: printing fitted CLI arguments to stdout...
  -c 131072 -ngl 49 -ot "blk\\.11\\.ffn_down.*=CPU,blk\\.12\\.ffn_(up|down|gate_up|gate)_(ch|)exps=CPU,blk\\.13\\.ffn_(up|down|gate_up|gate)_(ch|)exps=CPU,blk\\.14\\.ffn_(up|down|gate_up|gate)_(ch|)exps=CPU,blk\\.15\\.ffn_(up|down|gate_up|gate)_(ch|)exps=CPU,blk\\.16\\.ffn_(up|down|gate_up|gate)_(ch|)exps=CPU,blk\\.17\\.ffn_(up|down|gate_up|gate)_(ch|)exps=CPU,blk\\.18\\.ffn_(up|down|gate_up|gate)_(ch|)exps=CPU,blk\\.19\\.ffn_(up|down|gate_up|gate)_(ch|)exps=CPU,blk\\.20\\.ffn_(up|down|gate_up|gate)_(ch|)exps=CPU,blk\\.21\\.ffn_(up|down|gate_up|gate)_(ch|)exps=CPU,blk\\.22\\.ffn_(up|down|gate_up|gate)_(ch|)exps=CPU,blk\\.23\\.ffn_(up|down|gate_up|gate)_(ch|)exps=CPU,blk\\.24\\.ffn_(up|down|gate_up|gate)_(ch|)exps=CPU,blk\\.25\\.ffn_(up|down|gate_up|gate)_(ch|)exps=CPU,blk\\.26\\.ffn_(up|down|gate_up|gate)_(ch|)exps=CPU,blk\\.27\\.ffn_(up|down|gate_up|gate)_(ch|)exps=CPU,blk\\.28\\.ffn_(up|down|gate_up|gate)_(ch|)exps=CPU,blk\\.29\\.ffn_(up|down|gate_up|gate)_(ch|)exps=CPU,blk\\.30\\.ffn_(up|down|gate_up|gate)_(ch|)exps=CPU,blk\\.31\\.ffn_(up|down|gate_up|gate)_(ch|)exps=CPU,blk\\.32\\.ffn_(up|down|gate_up|gate)_(ch|)exps=CPU,blk\\.33\\.ffn_(up|down|gate_up|gate)_(ch|)exps=CPU,blk\\.34\\.ffn_(up|down|gate_up|gate)_(ch|)exps=CPU,blk\\.35\\.ffn_(up|down|gate_up|gate)_(ch|)exps=CPU,blk\\.36\\.ffn_(up|down|gate_up|gate)_(ch|)exps=CPU,blk\\.37\\.ffn_(up|down|gate_up|gate)_(ch|)exps=CPU,blk\\.38\\.ffn_(up|down|gate_up|gate)_(ch|)exps=CPU,blk\\.39\\.ffn_(up|down|gate_up|gate)_(ch|)exps=CPU,blk\\.40\\.ffn_(up|down|gate_up|gate)_(ch|)exps=CPU,blk\\.41\\.ffn_(up|down|gate_up|gate)_(ch|)exps=CPU,blk\\.42\\.ffn_(up|down|gate_up|gate)_(ch|)exps=CPU,blk\\.43\\.ffn_(up|down|gate_up|gate)_(ch|)exps=CPU,blk\\.44\\.ffn_(up|down|gate_up|gate)_(ch|)exps=CPU,blk\\.45\\.ffn_(up|down|gate_up|gate)_(ch|)exps=CPU,blk\\.46\\.ffn_(up|down|gate_up|gate)_(ch|)exps=CPU,blk\\.47\\.ffn_(up|down|gate_up|gate)_(ch|)exps=CPU,blk\\.48\\.ffn_(up|down|gate_up|gate)_(ch|)exps=CPU"
  """

  # Una salida con VARIAS líneas `mem=`: llama.cpp prueba configuraciones y las
  # escribe todas. La que vale es la última, y se comprueba con el `-ngl` de
  # los args.
  @varias_lineas """
  0.04.191.221 I common_params_fit_impl: id=0, n_layer= 0, n_part= 0, overflow_type=4, mem=   556 MiB
  0.04.191.230 I common_params_fit_impl: id=0, n_layer=49, n_part=38, overflow_type=4, mem=  7978 MiB
  0.04.191.236 I llama_fit_params: printing fitted CLI arguments to stdout...
  -c 131072 -ngl 49 -ot "blk\\.11\\.ffn_down.*=CPU"
  """

  describe "el peso" do
    test "es el ajustado, no el proyectado" do
      # El proyectado era 19053 con 11518 libres: si se reservara eso, la
      # reserva no cabría en el device y el modelo no arrancaría. El ajustado
      # es 10452, que sí cabe.
      assert {:ok, 10_452, _args} = FitParams.run_with_output(@real_output)
    end

    test "con varias lineas, gana la ultima" do
      assert {:ok, 7978, _args} = FitParams.run_with_output(@varias_lineas)
    end

    test "el proyectado NO es el peso" do
      {:ok, weight, _args} = FitParams.run_with_output(@real_output)

      # El `projected to use` de la salida es 19053: lo que haría falta si el
      # modelo entero cupiera en GPU. Reservar eso es reservar mas que la
      # memoria libre, la reserva se rechaza, y el modelo que necesita
      # recorte es justo el que no puede arrancar.
      refute weight == 19_053
      assert weight == 10_452
    end

    test "un peso que no cabe en el device se detecta antes de arrancar" do
      {:ok, weight, _args} = FitParams.run_with_output(@real_output)

      # 10452 cabe en los 11518 que ve el motor. Si el peso ajustado fuera
      # mayor que el libre, el ajuste habria fallado y no habria args.
      assert weight <= 11_518
    end
  end

  describe "los args ajustados" do
    test "el -ot llega SIN comillas" do
      {:ok, _weight, args} = FitParams.run_with_output(@real_output)

      # Con las comillas pegadas, llama-server responde `unknown buffer type`
      # y NO ARRANCA. Medido el 2026-10-21.
      refute Enum.any?(args, &String.contains?(&1, "\""))
    end

    test "el patron del -ot llega integro" do
      {:ok, _weight, args} = FitParams.run_with_output(@real_output)

      patron = Enum.at(args, Enum.find_index(args, &(&1 == "-ot")) + 1)

      assert String.starts_with?(patron, "blk\\.11\\.ffn_down.*=CPU")
      assert String.contains?(patron, "blk\\.48\\.ffn_")
    end

    test "el numero de capas y el que dice la linea de mem" do
      {:ok, _weight, args} = FitParams.run_with_output(@real_output)

      assert Enum.at(args, Enum.find_index(args, &(&1 == "-ngl")) + 1) == "49"
    end
  end

  describe "salidas que no son de fit-params" do
    test "no inventan un peso" do
      assert FitParams.run_with_output("") == :fallback
      assert FitParams.run_with_output("nada que ver aqui") == :fallback
    end
  end
end
