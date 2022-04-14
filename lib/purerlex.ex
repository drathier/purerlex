defmodule Mix.Tasks.Compile.Purerl do
  @moduledoc false

  use Mix.Task.Compiler

  @recursive true

  @default_cache_path "output/.purerlex.cache"
  @default_file_paths ["src/**/*.purs", "lib/**/*.purs", "test/**/*.purs"]
  @shell_prefix "PurerlEx: "

  @impl Mix.Task.Compiler
  def run(_argv) do
    config = Mix.Project.config() |> Keyword.get(:purerlex, Keyword.new())

    if System.find_executable("spago") do
      cached_build(config)
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

  defp read_cache(config, project_root_probably) do
    case File.read(project_root_probably <> "/" <> cache_path(config)) do
      {:ok, res} ->
        :erlang.binary_to_term(res)

      {:error, _err} ->
        ""
    end
  end

  defp write_cache(config, project_root_probably, contents, cmd_str) do
    path = project_root_probably <> "/" <> cache_path(config)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, :erlang.term_to_binary({cmd_str, contents}))
  end

  defp cached_build(config) do
    project_root_probably = Path.expand(File.cwd!())

    info(config, [@shell_prefix, "assuming the project root is `#{project_root_probably}`"])

    {old_cmd_str, cached} = read_cache(config, project_root_probably)

    purs_files =
      config
      |> file_paths()
      |> Enum.flat_map(&Path.wildcard/1)

    erl_files =
      purs_files
      |> Stream.map(&String.replace_suffix(&1, ".purs", ".erl"))
      |> Enum.filter(&File.exists?/1)

    files = purs_files ++ erl_files
    stats = Enum.map(files, fn x -> {x, File.stat!(x).mtime} end)

    if cached == stats && build_command(config) == old_cmd_str do
      info(config, [
        @shell_prefix,
        "no non-dep files changed; skipping running spago to save time."
      ])

      {:ok, []}
    else
      build(config, project_root_probably, stats)
    end
  end

  defp build(config, project_root_probably, stats) do
    cmd_str = build_command(config)

    Mix.shell().cmd(cmd_str, stderr_to_stdout: true)
    |> case do
      0 ->
        write_cache(config, project_root_probably, stats, cmd_str)
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

        Mix.shell().error([:bright, :red, @shell_prefix, error.message, :reset])
        {:error, [error]}
    end
  end

  defp build_command(config) do
    ["spago build" | spago_options(config)]
    |> Enum.join(" ")
    |> String.trim_trailing()
  end

  defp info(config, data) do
    unless quiet(config) do
      Mix.shell().info(data)
    end
  end

  defp quiet(config) do
    Keyword.get(config, :quiet, false)
  end

  defp file_paths(config) do
    Keyword.get(config, :file_paths, @default_file_paths)
  end

  defp spago_options(config) do
    lazy =
      config
      |> Keyword.get(:spago_options_lazy, fn -> [] end)

    strict =
      config
      |> Keyword.get(:spago_options, [])

    (lazy.() ++ strict)
    |> List.wrap()
  end

  defp cache_path(config) do
    Keyword.get(config, :cache_path, @default_cache_path)
  end
end
