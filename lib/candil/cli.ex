defmodule Candil.CLI do
  @moduledoc """
  The command line, declared.

  This module is a *declaration*, not an implementation. Parsing, the help
  renderer, the dispatch table, the `--no-color` bridge and the usage errors
  all belong to `Alaja.CLI.Definition`; the handlers behind `run` belong to the
  modules that own the behaviour.

  It used to be the other way round. The command table was a `@commands` map of
  module/name tuples, and each module ran its own `argv` by hand — a second
  argument parser that did not know about types, defaults, `--help`, or what a
  flag was *for*. The help was then built by hand from that same map. Every one
  of those was a place where the thing that gets typed and the thing that gets
  described could drift apart, which is exactly the bug the CI gate "the help
  must list every command the dispatch table has" was invented for: it caught a
  dispatch with a command the help did not mention, several releases too late.

  That gate is worth keeping. But a gate that exists because the design invited
  the bug is a bill for the design, and the drift was not hypothetical — see
  the flags on `run` below, four of which the parser had always accepted and the
  help had never mentioned.

  ## The two things that deliberately stay in Candil

  `Candil.CLI.Escript` owns the alias table (`--version`, `-v`, `model`…) and
  the terminal-capability decision. Neither belongs in the DSL, and the second
  is not a formality — see that module for why Alaja's own answer was not good
  enough.
  """

  # `halt_on_error` is deliberately NOT set, even though `Alaja.CLI` itself
  # sets it. The difference is what Candil is. Alaja is a binary; Candil is a
  # library that ships a binary, and `Candil.CLI.main/1` is callable in-process
  # by a host that embeds Candil — that is how the CLI is tested, and it is a
  # real thing a user can do. `halt_on_error` generates `System.halt/1`, which
  # is uncatchable, so it takes the caller's VM down with it: the test suite
  # died mid-run without a summary, which is a much more expensive way to
  # discover the same thing.
  #
  # The exit status does not need it. `Candil.CLI.Escript` translates whatever
  # a handler returned into an integer, and that is the number a shell reads.
  use Alaja.CLI.Definition,
    otp_app: :candil,
    command_help: true,
    usage_exit_code: 1,
    # An unknown top-level command is Candil's to answer, not the framework's:
    # it can suggest the nearest real one, and it returns `:error` so the
    # escript turns that into exit 1. Without a `catch_all`, Alaja's
    # `ErrorHandler` prints the error and returns `:ok`, so `candil
    # frobnicate` exited **0** — the same "failure that a script cannot see"
    # that `doctor` had.
    catch_all: {Candil.CLI.Escript, :unknown}

  alias Candil.CLI.{Doctor, Help, Lifecycle, Models, Router, Version}

  # The name aliases (`-v`, `--version`, `model`) are rewritten in
  # `Candil.CLI.Escript` before dispatch: `command/3` has no `aliases:`, only
  # flags and arguments do. Declaring them as five extra `command/3` blocks
  # would have put five phantoms in `candil --help`, and the help is supposed to
  # *be* the declaration.

  command "version", "Print the version and exit" do
    run({Version, :run})
  end

  command "help", "Print this" do
    run({Help, :run})
  end

  # A group needs a handler, not just its children. Without one, an unknown
  # subcommand falls through to trying to run the group itself, and Alaja says
  # "command 'models' has no handler defined" — which is a message about
  # Candil's internals, shown to a user who typed a model command wrong.
  subcommand "route", "Which model would answer this prompt" do
    run({Router, :unknown})

    command "ask", "Route one prompt and say which model wins and why" do
      argument(:prompt, :string, required: true, help: "the prompt to route")

      flag(:model, :string, help: "force a model, and skip every other layer")
      flag(:consumer, :string, default: "default", help: "which consumer is asking")

      run({Router, :run})
    end

    command "pin", "Show the pinned model, or pin one" do
      argument(:model, :string, required: false, help: "model alias; omit to just show")
      flag(:consumer, :string, default: "default", help: "which consumer")

      run({Router, :pin})
    end

    command "unpin", "Forget the pinned model" do
      flag(:consumer, :string, default: "default", help: "which consumer")
      run({Router, :unpin})
    end
  end

  subcommand "models", "Inspect, pull and remove models" do
    run({Models, :unknown})

    command "list", "Every model the store knows about" do
      run({Models, :list})
    end

    command "info", "Show one model in detail" do
      argument(:alias, :string, required: true, help: "model alias")

      run({Models, :info})
    end

    command "pull", "Fetch a model into the store" do
      argument(:alias, :string, required: true, help: "model alias")

      run({Models, :pull})
    end

    command "remove", "Delete a model from the store" do
      argument(:alias, :string, required: true, help: "model alias")

      run({Models, :remove})
    end
  end

  # The flags below are the ones `@switches` in `Lifecycle` had always
  # accepted — `--force`, `--cpu`, `--yes`, and the `-p/-f/-d/-y` short forms.
  # Four of the five were invisible in the help. Declaring them is what makes
  # them discoverable, and because the parser and the description are now the
  # same object they cannot drift apart again.
  command "run", "Start a model" do
    argument(:model, :string, required: true, help: "model alias to start")

    flag(:detach, :boolean,
      default: false,
      aliases: ["d"],
      help: "keep running after the terminal exits"
    )

    flag(:port, :integer,
      aliases: ["p"],
      help: "port to bind, if the profile does not set one"
    )

    flag(:force, :boolean,
      default: false,
      aliases: ["f"],
      help: "start even when a preflight check complains"
    )

    flag(:cpu, :boolean, default: false, help: "bind to the CPU instead of the GPU")

    flag(:yes, :boolean, default: false, aliases: ["y"], help: "assume yes for the confirmation")

    run({Lifecycle, :run_model})
  end

  command "stop", "Stop one model, or every model" do
    argument(:model, :string, help: "model alias, or `all` (the default)")

    run({Lifecycle, :stop})
  end

  command "status", "What is running, and is it answering" do
    flag(:json, :boolean, default: false, help: "machine-readable output, undecorated")

    run({Lifecycle, :status})
  end

  command "init", "Write a commented candil.toml to get started" do
    flag(:force, :boolean, default: false, help: "overwrite an existing config")
    flag(:path, :string, help: "write here instead of the default location")

    run({Candil.CLI.Init, :run})
  end

  command "doctor", "Check this machine and say how to fix it" do
    flag(:fix, :boolean, default: false, help: "apply the safe fixes and re-check")
    flag(:json, :boolean, default: false, help: "machine-readable output, undecorated")

    run({Doctor, :run})
  end

  @doc """
  Every declared command name, as the CI gate consumes them.

  The DSL keeps its declaration in `__commands__/0` as a list of command maps;
  the gate wants the names, and `Map.keys/1` over a list is not a thing. This
  keeps the gate reading the *declaration* rather than the rendering, which is
  the whole point of it — and the subcommands come along for free, because they
  are declared in the same place the top-level ones are.
  """
  @spec command_names() :: [binary()]
  def command_names do
    __commands__() |> Enum.map(& &1.name) |> Enum.sort()
  end

  @doc """
  Every command *and subcommand*, for anything that needs the whole surface.

  Not what the CI gate uses: `candil --help` lists the top level, and `models
  list` is not missing from it — it is under `models`, which is.
  """
  @spec all_command_names() :: [binary()]
  def all_command_names do
    __commands__()
    |> Enum.flat_map(fn command ->
      [command.name | Enum.map(Map.keys(command.subcommands), &to_string/1)]
    end)
    |> Enum.sort()
  end
end
