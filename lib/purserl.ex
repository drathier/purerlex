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

    state = %{
      port: nil,
      caller: nil,
      purs_cmd: nil,
      purs_args: Keyword.get(config, :purs_args, "")
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
        IO.puts(msg)
        {:noreply, state}
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
            #IO.inspect {"purerlex: likely file system race condition, sleeping for #{sleep_time}ms before retrying erlc call"}
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
end
