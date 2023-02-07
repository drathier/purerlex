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
      caller: nil
    }

    {:ok, state, {:continue, :start_compiler}}
  end

  @impl true
  def handle_continue(:start_compiler, state) do
    {:ok, cmd} = get_purs_call()
    # NOTE[fh]: has to be charlist strings ('qwe'), not binary strings ("qwe")
    port = Port.open({:spawn, cmd}, [:binary, :exit_status, :stderr_to_stdout, {:env, [{'PURS_LOOP_EVERY_SECOND', '1'}]}, {:line, 999_999_999}])
    state = %{state | port: port}
    IO.puts("Purserl compiler started")
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, {:eol, msg}}}, state) do
    case msg |> String.starts_with?("###") do
      true ->
        case msg do
          "### launching compiler" ->
            {:noreply, state}

          "### read externs" ->
            {:noreply, state}

          "### done compiler: 0" ->
            GenServer.reply(state.caller, :ok)
            {:noreply, %{state | caller: nil}}

          other ->
            IO.inspect({:meta, :unhandled, other})
        end

        {:noreply, state}

      false ->
        IO.puts("> " <> msg)
        {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, exit_status}}, state) do
    msg = "Purs exited unexpectedly with code #{exit_status}"
    IO.puts(msg)
    {:stop, msg, state}
  end

  @impl true
  def handle_call(:shutdown_compiler, from, state) do
    Port.close(state.port)
    {:stop, "was told to stop", state}
  end

  def handle_call(:recompile, from, state) do
    res = Port.command(state.port, 'sdf\n', [])
    {:noreply, %{state | caller: from}}
  end

  ###

  def trigger_recompile(pid) do
    res = GenServer.call(pid, :recompile)
    res
  end

  def trigger_exit(pid) do
    res = GenServer.call(pid, :shutdown_compiler)
    res
  end

  ###

  def build() do
    cmd_str = build_command()

    Mix.shell().cmd(cmd_str, stderr_to_stdout: true, env: [{"PURS_LOOP_EVERY_SECOND", "0"}])
    |> case do
      0 ->
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

  defp build_command() do
    "spago build --purs-args \"--codegen erl\" -v --no-psa"
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
      {res, 0} ->
        {:ok, res}
        split_str = "Running command: `purs compile"

        line =
          res
          |> String.split("\n")
          |> Enum.find(fn x -> x |> String.contains?(split_str) end)

        [_debug, args_with_end] = line |> String.split(split_str, parts: 2)
        [args, _end] = args_with_end |> String.split("`", parts: 2)
        {:ok, "purs compile " <> args}

      {err, exit_status} ->
        error = %Mix.Task.Compiler.Diagnostic{
          compiler_name: "purerl-mix-compiler",
          details: err,
          file: "spago",
          message: "non-zero exit code #{exit_status} from `#{cmd_str}`",
          position: nil,
          severity: :error
        }

        Mix.shell().error([:bright, :red, @shell_prefix, error.message, :reset])
        {:error, [error]}
    end
  end
end
