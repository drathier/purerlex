defmodule Mix.Tasks.Compile.Purerl do
  @moduledoc false

  use Mix.Task.Compiler

  @recursive true

  @cache_path "output/.purerlex.cache"
  @file_paths ["src/**/*.purs", "lib/**/*.purs", "test/**/*.purs"]
  @shell_prefix "PurerlEx: "

  @impl Mix.Task.Compiler
  def run(_argv) do
    if System.find_executable("spago") do
      cached_build()
    else
      {
        :error,
        [
          %Mix.Task.Compiler.Diagnostic{
            compiler_name: "purerl-mix-compiler",
            details: nil,
            file: "spago",
            message:
              "Couldn't find `spago` executable on path. Purerl mix compiler task will not work without it. Please install it on path or remove the :purerl compiler from mix.exs.",
            position: nil,
            severity: :error
          }
        ]
      }
    end
  end

  defp read_cache(project_root_probably) do
    case File.read(project_root_probably <> "/" <> @cache_path) do
      {:ok, res} ->
        :erlang.binary_to_term(res)

      {:error, _err} ->
        ""
    end
  end

  defp write_cache(project_root_probably, contents) do
    path = project_root_probably <> "/" <> @cache_path
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, :erlang.term_to_binary(contents))
  end

  defp cached_build() do
    project_root_probably = Path.expand(File.cwd!())

    Mix.shell().info([@shell_prefix, "assuming the project root is `#{project_root_probably}`"])

    cached = read_cache(project_root_probably)

    purs_files = Enum.flat_map(@file_paths, &Path.wildcard/1)

    erl_files =
      purs_files
      |> Stream.map(&String.replace(&1, ~r/\.purs\z/, ".erl"))
      |> Enum.filter(&File.exists?/1)

    files = purs_files ++ erl_files
    stats = Enum.map(files, fn x -> {x, File.stat!(x).mtime} end)

    if cached == stats do
      Mix.shell().info([
        @shell_prefix,
        "no non-dep files changed; skipping running spago to save time."
      ])

      {:ok, []}
    else
      build(project_root_probably, stats)
    end
  end

  defp build(project_root_probably, stats) do
    cmd_str = "spago build"

    Mix.shell().cmd(cmd_str, stderr_to_stdout: true)
    |> case do
      0 ->
        write_cache(project_root_probably, stats)
        {:ok, []}

      exit_status ->
        error = %Mix.Task.Compiler.Diagnostic{
          compiler_name: "purerl-mix-compiler",
          details: nil,
          file: "spago",
          message: "non-zero exit code #{exit_status} from `#{cmd_str}`",
          position: nil,
          severity: :error
        }

        Mix.shell().info([:bright, :red, @shell_prefix, error.message, :reset])
        {:error, [error]}
    end
  end
end
