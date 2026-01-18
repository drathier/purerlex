defmodule Mix.Tasks.Compile.Purserl do
  @moduledoc false

  use Mix.Task.Compiler

  alias Purserl, as: P

  @recursive true

  @impl Mix.Task.Compiler
  def run(_argv) do
    #IO.inspect({"###Mix.Task.Compiler (purserl)", "run", "argv", _argv})
    config = Mix.Project.config() |> Keyword.get(:purserl, Keyword.new())
    #IO.inspect({"###Mix.Task.Compiler (purserl)", "config", config})
    {:ok, _} = P.start(config)
    #IO.inspect({"###Mix.Task.Compiler (purserl)", "pid", pid})
    res = P.trigger_recompile(:sync)
    #IO.inspect({"###Mix.Task.Compiler (purserl)", "res", res})
    #P.trigger_exit(pid)
    #IO.inspect({"###Mix.Task.Compiler (purserl)", "shut-down", res})
    if System.get_env("PURSERL_SKIP") == "1" do
      :ok
    else
      res
    end
  end
end
