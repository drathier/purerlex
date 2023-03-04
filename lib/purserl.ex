defmodule DevHelpers.Purserl do
  use GenServer

  ###

  def start_link(config) do
    case GenServer.start_link(__MODULE__, config, name: :purserl_compiler) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      res -> res
    end
  end

  def env_varaibles() do
    [{'PURS_LOOP_EVERY_SECOND', '1'}, {'PURS_FORCE_COLOR', '1'}]
  end

  @impl true
  def init(config) do
    # 1. run spago to get at the `purs` cmd it builds
    # 2. terminate spago as soon as it prints its `purs` cmd
    # 3. run that `purs` cmd ourselves
    # 4. init is done
    # 5. repeat step 3 forever, on `recompile`

    IO.inspect({:init_purserl, config})

    state = %{
      port: nil,
      caller: nil,
      purs_cmd: nil,
      purs_args: config |> Keyword.get(:purs_args, "")
    }

    {:ok, state} = start_spago(state)

    {:ok, state}
  end

  def start_spago(state) do
    # NOTE[fh]: cmd has to be charlist strings ('qwe'), not binary strings ("qwe")
    cmd = 'spago build --purs-args \"--codegen erl\" -v --no-psa'

    port =
      Port.open({:spawn, cmd}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:env, [{'PURS_LOOP_EVERY_SECOND', '0'}]},
        {:line, 999_999_999}
      ])

    state = %{state | port: port}
    {:ok, state}
  end

  def run_purs(state) do
    IO.inspect({:run_purs, state})

    port =
      Port.open({:spawn, state.purs_cmd <> " " <> state.purs_args}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:env, env_varaibles()},
        {:line, 999_999_999}
      ])

    # send one newline to trigger a first recompile, in case nothing needed to be rebuilt. Out handle_info is looking for a "done compiler" message, which is printed when compilation finishes
    _ = Port.command(port, 'first\n', [])

    {:ok, %{state | port: port}}
  end

  @impl true
  def handle_info({_port, {:data, {:eol, msg}}}, state) do
    cond do
      # spago
      msg |> String.contains?("Running command: `purs compile") ->
        Port.close(state.port)

        {:ok, cmd} = extract_purs_cmd(msg)
        {:ok, state} = run_purs(%{state | port: nil, purs_cmd: cmd})
        {:noreply, state}

      state.purs_cmd == nil ->
        {:noreply, state}

      # purs
      msg |> String.starts_with?("###") ->
        cond do
          msg == "### launching compiler" ->
            {:noreply, state}

          msg == "### read externs" ->
            {:noreply, state}

          msg |> String.starts_with?("### done compiler: 0") ->
            GenServer.reply(state.caller, :ok)
            {:noreply, %{state | caller: nil}}

          msg |> String.starts_with?("### done compiler: 1") ->
            GenServer.reply(state.caller, :err)
            {:noreply, %{state | caller: nil}}

          msg |> String.starts_with?("### erl-same:") ->
            {:noreply, state}

          msg |> String.starts_with?("### erl-diff:") ->
            ["", path_to_changed_file] = msg |> String.split("### erl-diff:", parts: 2)

            # calling erlang compiler on files as we go; purs will continue running in its own thread and we'll read its next output when we're done compiling this file. This hopefully and apparently speeds up erlang compilation.
            cond do
              path_to_changed_file |> String.ends_with?(".erl") ->
                compile_erlang(path_to_changed_file)

              true ->
                nil
            end

            {:noreply, state}

          true ->
            {:noreply, state}
        end

      true ->
        # is it json errors?
        case Jason.decode(msg) do
          {:ok, v} ->
            # yes, now do stuff with it
            IO.puts("==== json parsed ok ====")
            IO.puts(inspect({:got_json, v}, width: 80))
            process_warnings(v["warnings"])

            {:noreply, state}

          {:error, _} ->
            # nope, print it
            IO.puts(msg)
            {:noreply, state}
        end
    end
  end

  def handle_info({_port, {:exit_status, exit_status}}, state) do
    msg = "Purs exited unexpectedly with code #{exit_status}"
    IO.puts(msg)
    {:stop, msg, state}
  end

  @impl true
  def handle_call(:shutdown_compiler, _from, state) do
    Port.close(state.port)
    {:stop, "was told to stop", state}
  end

  def handle_call(:recompile, from, state) do
    _ = Port.command(state.port, 'sdf\n', [])
    {:noreply, %{state | caller: from}}
  end

  ###

  def trigger_recompile(pid) do
    res = GenServer.call(pid, :recompile, :infinity)

    case res do
      :ok ->
        {:ok, []}

      :err ->
        {
          :error,
          [
            %Mix.Task.Compiler.Diagnostic{
              compiler_name: "purserl-mix-compiler",
              details: nil,
              file: "purserl",
              message: "Purs compilation failed.",
              position: nil,
              severity: :error
            }
          ]
        }
    end
  end

  def trigger_exit(pid) do
    res = GenServer.call(pid, :shutdown_compiler)
    res
  end

  ###

  # Compiles and loads an Erlang source file, returns {module, binary}
  defp compile_erlang(source, retries \\ 0) do
    source = Path.relative_to_cwd(source) |> String.to_charlist()

    case :compile.file(source, [:binary, :report]) do
      {:ok, module, binary} ->
        # write newly compiled file to disk as beam file
        base = source |> Path.basename() |> Path.rootname()
        File.write!(Path.join(Mix.Project.compile_path(), base <> ".beam"), binary)

        # reload in memory
        :code.purge(module)
        {:module, module} = :code.load_binary(module, source, binary)
        {module, binary}

      _ ->
        cond do
          retries <= 10 ->
            sleep_time = retries * 100
            Process.sleep(sleep_time)
            # IO.inspect {"purerlex: likely file system race condition, sleeping for #{sleep_time}ms before retrying erlc call"}
            compile_erlang(source, retries + 1)

          true ->
            IO.puts("#############################################################################")
            IO.puts("####### Erl compiler failed to run; something has gone terribly wrong #######")
            IO.puts("#############################################################################")
            raise CompileError
        end
    end
  end

  def spawn_port(cmd) do
    # cmd_str = "spago build --purs-args \"--codegen erl\" -v --no-psa"
    port = Port.open({:spawn, cmd}, [:binary, {:env, env_varaibles()}])
    port
  end

  def extract_purs_cmd(line) do
    split_str = "Running command: `purs compile"

    [_debug, args_with_end] = line |> String.split(split_str, parts: 2)
    [args, _end] = args_with_end |> String.split("`", parts: 2)
    {:ok, "purs compile " <> args}
  end

  def process_warnings(warnings) do
    # warnings = [
    #  %{
    #    "allSpans" => [
    #      %{"end" => [22, 12], "name" => "lib/Shell.purs", "start" => [22, 1]}
    #    ],
    #    "errorCode" => "MissingTypeDeclaration",
    #    "errorLink" => "https://github.com/purescript/documentation/blob/master/errors/MissingTypeDeclaration.md",
    #    "filename" => "lib/Shell.purs",
    #    "message" =>
    #      "  No type declaration was provided for the top-level declaration of asdf.\n  It is good practice to provide type declarations as a form of documentation.\n  The inferred type of asdf was:\n\n    Int\n\n\nin value declaration asdf\n",
    #    "moduleName" => "Shell",
    #    "position" => %{
    #      "endColumn" => 12,
    #      "endLine" => 22,
    #      "startColumn" => 1,
    #      "startLine" => 22
    #    },
    #    "suggestion" => %{
    #      "replaceRange" => %{
    #        "endColumn" => 1,
    #        "endLine" => 22,
    #        "startColumn" => 1,
    #        "startLine" => 22
    #      },
    #      "replacement" => "asdf :: Int\n\n"
    #    }
    #  }
    # ]

    not_in_spago =
      warnings
      |> Enum.filter(fn x ->
        case x do
          %{"filename" => ".spago/" <> _} -> false
          _ -> true
        end
      end)

    has_suggestion =
      not_in_spago
      |> Enum.filter(fn x ->
        case x do
          %{"suggestion" => _} -> true
          _ -> false
        end
      end)

    should_be_applied =
      has_suggestion
      |> Enum.filter(fn x ->
        case x do
          %{"errorCode" => error_code, "suggestion" => %{"replacement" => replacement}} ->
            case error_code do
              "UnusedImport" ->
                true

              "DuplicateImport" ->
                true

              "UnusedExplicitImport" ->
                true

              "UnusedDctorImport" ->
                true

              "UnusedDctorExplicitImport" ->
                true

              "ImplicitImport" ->
                cond do
                  replacement |> String.starts_with?("import Joe") -> false
                  replacement |> String.starts_with?("import Prelude") -> false
                  true -> true
                end

              "ImplicitQualifiedImport" ->
                true

              "ImplicitQualifiedImportReExport" ->
                false

              "HidingImport" ->
                true

              "MissingTypeDeclaration" ->
                true

              "MissingKindDeclaration" ->
                true

              "WildcardInferredType" ->
                false

              "WarningParsingCSTModule" ->
                true

              _ ->
                IO.inspect({"###", "UNHANDLED_SUGGESTION_TAG", "please post this dump to the purerlex developers at https://github.com/drathier/purerlex/issues/new", x})
                false
            end

          _ ->
            false
        end
      end)

    reverse_sorted_applications =
      should_be_applied
      |> Enum.sort_by(fn %{"suggestion" => %{"replaceRange" => %{"startColumn" => start_column, "startLine" => start_line, "endColumn" => end_column, "endLine" => end_line}}} ->
        {start_line, start_column, end_line, end_column}
      end)
      |> Enum.reverse

    reverse_sorted_applications
    |> Enum.map(fn x -> apply_suggestion(x) end)

    # [drathier]: do we need to sort the errors?

    # has_suggestion
  end

  def apply_suggestion(%{
        "filename" => filename,
        "suggestion" => %{
          "replaceRange" => %{
            "startColumn" => start_column,
            "startLine" => start_line,
            "endColumn" => end_column,
            "endLine" => end_line
          },
          "replacement" => replacement
        }
      }) do
    IO.inspect({"applying suggestion", filename, replacement})
    r_prefix_lines = "(?<prefix_lines>(([^\n]*\n){#{start_line - 1}}))"
    r_prefix_columns = "(?<prefix_columns>(.{#{start_column - 1}}))"
    r_infix_columns = "(?<infix_columns>(.{#{end_column - start_column}}))"
    r_infix_lines = "(?<infix_lines>(([^\n]*\n){#{end_line - start_line}}))"
    r_suffix_columns = "(?<suffix_columns>[^\n]*\n)"
    r_suffix_lines = "(?<suffix_lines>[\\S\\s]*)"

    r =
      r_prefix_lines <>
        r_prefix_columns <>
        r_infix_columns <>
        r_infix_lines <>
        r_suffix_columns <>
        r_suffix_lines

    old_content = File.read!(filename)

    reg = Regex.named_captures(Regex.compile!(r), old_content)

    # TODO[drathier]: why is there two trailing newlines in the suggested replacement?
    cleaned_replacement =
      replacement
      |> String.replace_suffix("\n\n", "\n")

    new_content =
      reg["prefix_lines"] <>
        reg["prefix_columns"] <>
        cleaned_replacement <>
        reg["suffix_columns"] <>
        reg["suffix_lines"]

    # IO.puts("=== v pre")
    # IO.puts(old_content)
    # IO.puts("=== v post")
    # IO.puts(new_content)
    # IO.puts("=== end")

    if new_content != old_content do
      :ok = File.write!(filename, new_content)
      :applied_suggestion
    else
      :no_change
    end
  end
end
