defmodule Mix.Tasks.Compile.Purserl do
  @moduledoc false

  use Mix.Task.Compiler

  alias DevHelpers.Purserl, as: P

  @recursive true

  @impl Mix.Task.Compiler
  def run(_argv) do
    #config = Mix.Project.config() |> Keyword.get(:purerlex, Keyword.new())
    {:ok, pid} = P.start_link()
    P.trigger_recompile(pid)
  end
end
