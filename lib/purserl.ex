defmodule DevHelpers.Purserl do
  use GenServer

  ###

  def start_link() do
    case GenServer.start_link(__MODULE__, nil, name: :purserl_compiler) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      res -> res
    end
  end

  """
  alias DevHelpers.Purserl, as: P
  {:ok, pid} = P.start_link()
  P.trigger_recompile(pid)
  P.trigger_recompile(pid)
  P.trigger_exit(pid)
  """

  @impl true
  def init(_) do
    state = %{
      port: nil,
      caller: nil,
      changed_files: []
    }

    {:ok, cmd} = get_purs_call()
    # NOTE[fh]: has to be charlist strings ('qwe'), not binary strings ("qwe")
    port =
      Port.open({:spawn, cmd}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:env, [{'PURS_LOOP_EVERY_SECOND', '1'}]},
        {:line, 999_999_999}
      ])

    state = %{state | port: port}
    IO.puts("Purserl compiler started")

    {:ok, state}
  end

  @impl true
  def handle_info({_port, {:data, {:eol, msg}}}, state) do
    case msg |> String.starts_with?("###") do
      true ->
        cond do
          msg == "### launching compiler" ->
            {:noreply, state}

          msg == "### read externs" ->
            {:noreply, state}

          msg |> String.starts_with?("### done compiler:") ->
            state.changed_files
            |> Enum.map(fn m ->
              _ = compile_erlang(m)
            end)

            GenServer.reply(state.caller, :ok)
            {:noreply, %{state | caller: nil, changed_files: []}}

          msg |> String.starts_with?("### erl-same:") ->
            {:noreply, state}

          msg |> String.starts_with?("### erl-diff:") ->
            ["", path_to_changed_file] = msg |> String.split("### erl-diff:", parts: 2)
            {:noreply, %{state | changed_files: [path_to_changed_file | state.changed_files]}}

          true ->
            {:noreply, state}
        end

      false ->
        IO.puts("> " <> msg)
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
    res
  end

  def trigger_exit(pid) do
    res = GenServer.call(pid, :shutdown_compiler)
    res
  end

  ###

  # Compiles and loads an Erlang source file, returns {module, binary}
  defp compile_erlang(source) do
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
        raise CompileError
    end
  end

  def spawn_port(cmd) do
    # cmd_str = "spago build --purs-args \"--codegen erl\" -v --no-psa"
    port = Port.open({:spawn, cmd}, [:binary, {:env, [{'PURS_LOOP_EVERY_SECOND', '1'}]}])
    port
  end

  def get_purs_call() do
    cmd_str = "spago build --purs-args \"--codegen erl\" -v --no-psa"

    System.shell(cmd_str, stderr_to_stdout: true, env: [{"PURS_LOOP_EVERY_SECOND", "0"}])
    |> case do
      {res, _} ->
        {:ok, res}
        split_str = "Running command: `purs compile"

        line =
          res
          |> String.split("\n")
          |> Enum.find(fn x -> x |> String.contains?(split_str) end)

        [_debug, args_with_end] = line |> String.split(split_str, parts: 2)
        [args, _end] = args_with_end |> String.split("`", parts: 2)
        {:ok, "purs compile " <> args}
    end
  end
end
