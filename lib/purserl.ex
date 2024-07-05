defmodule DevHelpers.Purserl do
  use GenServer
  alias IO.ANSI, as: Color

  # """
  # x = {"2023-05-15T13:12:07.843447Z", "handle_info", "{\"warnings .... # i.e. whole log handle_info line
  # {_, _, inp} = x
  # Process.send(:purserl_compiler, {42, {:data, {:eol, inp}}}, [])
  # """

  ###

  @name :purserl_compiler

  def start(config) do
    case GenServer.start(__MODULE__, config, name: @name) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      res -> res
    end
  end

  def env_variables() do
    [{'PURS_LOOP_EVERY_SECOND', '1'}, {'PURS_FORCE_COLOR', '1'}]
  end

  @impl true
  def init(config) do
    # 1. run spago to get at the `purs` cmd it builds
    # 2. terminate spago as soon as it prints its `purs` cmd
    # 3. run that `purs` cmd ourselves
    # 4. init is done
    # 5. repeat step 3 forever, on `recompile`

    # IO.inspect({:init_purserl, config})

    state = %{
      port: nil,
      caller: [],
      purs_cmd: config |> Keyword.get(:purs_cmd, nil),
      extract_cmd: config |> Keyword.get(:purs_cmd, "") == "",
      purs_args: config |> Keyword.get(:purs_args, ""),
      ctx_lines_above: config |> Keyword.get(:ctx_lines_above, 3) |> (fn x -> x + 1 end).(),
      ctx_lines_below: config |> Keyword.get(:ctx_lines_below, 3) |> (fn x -> x + 1 end).(),
      single_line_compile_output: config |> Keyword.get(:single_line_compile_output, false),
      logfile:
        case config |> Keyword.get(:logfile_path, nil) do
          nil ->
            nil

          path ->
            dirpath =
              path
              |> String.reverse()
              |> String.split("/", parts: 2)
              |> Enum.reverse()
              |> List.first("")
              |> String.reverse()

            with :ok <- File.mkdir_p(dirpath),
                 {:ok, file} <- File.open(path, [:utf8, :append]) do
              file
            else
              err ->
                runtime_bug(
                  nil,
                  {"purerlex: failed to create folders or open file, disabling debug logging",
                   {:logfile_path, path}, {:err, err}}
                )

                nil
            end
        end,
      build_error_cache: config |> Keyword.get(:build_error_cache, nil),
      tasks: [],
      module_positions: %{},
      erl_steps: %{},
      started_at: nil,
    }

    log("init", {config, System.get_env()}, state.logfile)

    # NOTE[drathier]: don't attempt this shit anymore. Just put in `erlc_paths: ["output"]` and live with it. It's incredibly hard to speed things up further. Whenever it starts recompiling 30+ files for no reason, nuke the entire _build folder and do a clean build.
    # IO.inspect({:pre_mix_erlang})
    # res = Mix.Tasks.Compile.Erlang.run([erlc_paths: ["output"]])
    # IO.inspect({:done_mix_erlang, res})

    # compile all erl files, so we can recover from aborted builds and so that this runs in CI
    # files = Mix.Utils.extract_files(["output"], [:erl])
    # IO.inspect({:start_prebuild_erlc, files})
    # files |> Enum.map(fn x -> compile_erlang(x) end)
    # IO.inspect({:done_prebuild_erlc, files})

    {:ok, state} = if state.purs_cmd == nil do
      start_spago(state)
    else
      run_purs(state)
    end

    {:ok, state}
  end

  def start_spago(state) do
    # NOTE[fh]: cmd has to be charlist strings ('qwe'), not binary strings ("qwe")
    cmd = 'spago build --purs-args \"--codegen erl\" -v --no-psa'

    port =
      port_open(
        {:spawn, cmd},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:env, [{'PURS_LOOP_EVERY_SECOND', '0'}]},
          {:line, 999_999_999}
        ],
        state
      )

    state = %{state | port: port}
    {:ok, state}
  end

  def run_purs(state) do
    port =
      port_open(
        {:spawn, state.purs_cmd <> " " <> state.purs_args},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:env, env_variables()},
          {:line, 999_999_999}
        ],
        state
      )

    {:ok, %{state | port: port}}
  end

  # logging wrappers
  def port_open(arg, opts, state) do
    log("port_open", {arg, opts}, state.logfile)
    Port.open(arg, opts)
  end

  def port_command(port, msg, opts, state) do
    log("port_command", {port, msg, opts}, state.logfile)
    Port.command(port, msg, opts)
  end

  def port_close(port, state) do
    log("port_close", {port}, state.logfile)
    Port.close(port)
  end

  def log(tag, msg, logfile) do
    case logfile do
      nil ->
        nil

      f ->
        contents = {self(), DateTime.utc_now() |> DateTime.to_iso8601(), tag, msg}

        contents_str =
          inspect(contents, width: :infinity, printable_limit: :infinity, limit: :infinity)

        IO.puts(f, contents_str)
    end

    nil
  end

  def print_pretty_status(state, module) do
    {pos, step_in_brackets, s_version} = state.module_positions[module]
    rows = :maps.size(state.module_positions)
    label =
      case state.erl_steps[module] do
        nil -> "Purs"
        n when is_integer(n) -> String.duplicate("*", min(n, 4)) <> String.duplicate(" ", 4 - min(n, 4))
      end
    overwrite = label != "Purs"
    move_up =
      case overwrite do
        true -> String.duplicate(Color.cursor_up(), rows - pos)
        false -> ""
      end
    move_down =
      case overwrite do
        true -> String.duplicate(Color.cursor_down(), rows - pos - 1)
        false -> ""
      end
    clear =
      case overwrite do
        true -> Color.clear_line
        false -> ""
      end
    case :io.rows() do
      {:ok, n} when n > rows - pos ->
        # [ 0 of 0 ] SXX Purs Module.Mod
        IO.write(move_up <> clear <> "#{step_in_brackets} #{s_version} #{label} #{module}\n" <> move_down)
      {:error, :enotsup} when not overwrite ->
        IO.write("#{step_in_brackets} #{s_version} #{label} #{module}\n")
      _ ->
        nil
    end
  end

  @impl true
  def handle_info({_port, {:data, {:eol, msg}}}, state) do
    # log whenever we get something, if applicable
    log("handle_info", msg, state.logfile)

    cond do
      # spago
      msg |> String.contains?("Running command: `purs compile") and state.extract_cmd ->
        port_close(state.port, state)

        {:ok, cmd} = extract_purs_cmd(msg)
        {:ok, state} = run_purs(%{state | port: nil, purs_cmd: cmd})
        {:noreply, state}

      state.purs_cmd == nil ->
        {:noreply, state}

      # purs
      msg |> String.starts_with?("###") ->
        cond do
          msg == "### launching compiler" ->
            IO.puts("Compiling ...")
            {:noreply, %{ state | started_at: DateTime.utc_now(), module_positions: %{}, erl_steps: %{} }}

          msg == "### read externs" ->
            {:noreply, state}

          msg |> String.starts_with?("### done compiler: 0") ->
            state = await_tasks(state)
            GenServer.cast(@name, {:finish_up, :ok})
            {:noreply, state}

          msg |> String.starts_with?("### done compiler: 1") ->
            state = await_tasks(state)
            GenServer.cast(@name, {:finish_up, :err})
            {:noreply, state}

          msg |> String.starts_with?("### erl-same:") ->

            "### erl-same:" <> path_to_changed_file = msg
            case path_to_changed_file |> String.split("/") do
              ["output", module | _ ] ->
                GenServer.cast(@name, {:erl_step_complete, module})
              _ -> nil
            end

            {:noreply, state}

          msg |> String.starts_with?("### erl-diff:") ->

            "### erl-diff:" <> path_to_changed_file = msg

            module_name =
              case path_to_changed_file |> String.split("/") do
                ["output", module | _ ] ->
                  module
                _ ->
                  nil
              end

            # calling erlang compiler on files as we go; purs will continue running in its own thread and we'll read its next output when we're done compiling this file. This hopefully and apparently speeds up erlang compilation.
            state = cond do
              path_to_changed_file |> String.ends_with?(".erl") ->
                %{ state | tasks: [spawn_link(__MODULE__, :compile_erlang, [path_to_changed_file, module_name, state.logfile])|state.tasks] }

              true ->
                state
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
            process_warnings(state, DateTime.utc_now(), v["warnings"], v["errors"], :wip)

            {:noreply, state}

          {:error, _} ->
            # nope, is it a "[123 of 456] Compiling ..." line?
            cond do
              msg |> String.contains?(" Compiling ") ->
                # [ 848 of 1058] Compiling S64 Lesslie.Fortnox.Streams.Storage
                [step_in_brackets, v_and_mod] = msg |> String.split(" Compiling ", parts: 2)
                [s_version, module] = v_and_mod |> String.split(" ", parts: 2)

                module_info = {:maps.size(state.module_positions), step_in_brackets, s_version}
                state = %{ state | module_positions: state.module_positions |> Map.put(module, module_info)}
                print_pretty_status(state, module)

                # IO.inspect {:s_version, s_version, :module, module}

                del_cache(state.logfile, state.build_error_cache, module)

                {:noreply, state}

              # nope, is it "purs compile: No files found using pattern: src/**/*.purs"?
              msg |> String.contains?("No files found using pattern: src/**/*.purs") ->
                {:noreply, state}

              true ->
                # nope, print it
                IO.puts(msg)
                {:noreply, state}
            end
        end
    end
  end

  def handle_info({_port, {:exit_status, exit_status}}, state) do
    msg = "Purs exited unexpectedly with code #{exit_status}"
    IO.puts(msg)
    {:stop, msg, state}
  end

  @impl true
  def handle_cast({:erl_step_complete, module}, state) do
    state = %{ state | erl_steps: state.erl_steps |> Map.put(module, 1 + (state.erl_steps[module] || 0)) }
    print_pretty_status(state, module)
    {:noreply, state}
  end
  def handle_cast({:finish_up, result}, state) do
    process_warnings(state)
    print_elapsed(state)
    reply(state, state.caller, result)
    {:noreply, state}
  end

  @impl true
  def handle_call(:shutdown_compiler, _from, state) do
    port_close(state.port, state)
    {:stop, :normal, state}
  end

  def handle_call(:error_cache, _from, state) do
    {:reply, warnings_to_string(state), state}
  end

  def handle_call(:recompile, from, state) do
    # NOTE[drathier]: elixir usually only runs one compiler pass at a time, but there are a few (probably unintentional) exceptions which cause total havoc. This case is a workaround for that.
    case state.caller do
      [] ->
        # NOTE[em]: This is what triggers the compiler
        _ = port_command(state.port, 'sdf\n', [], state)

      _ ->
        # IO.puts(inspect({"[purerlex]: skipping duplicate concurrent recompile", from, state.caller}, width: 2000))
        :already_running
    end

    {:noreply, %{state | caller: [from | state.caller]}}
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
  def compile_erlang(source, module_name, logfile, retries \\ 0) do
    log("compile_erlang", {source, retries}, logfile)

    source = Path.relative_to_cwd(source) |> String.to_charlist()

    # st = DateTime.utc_now()
    case :compile.file(source, [:binary, :return_warnings]) do
      {:ok, module, binary, warnings} ->
        # write newly compiled file to disk as beam file
        base = source |> Path.basename() |> Path.rootname()
        target_path = Path.join(Mix.Project.compile_path(), base <> ".beam")

        log(
          "compile_erlang:compiled_ok",
          {source, retries, target_path, "warnings", warnings},
          logfile
        )

        File.write!(target_path, binary)

        # reload in memory
        :code.purge(module)
        :code.delete(module)
        log("compile_erlang:purged", {source, retries, target_path}, logfile)
        {:module, module} = :code.load_binary(module, source, binary)
        log("compile_erlang:loaded", {source, retries, target_path}, logfile)
        {module, binary}

      err ->
        log("compile_erlang:not-ok", {source, retries, err}, logfile)

        cond do
          retries <= 10 ->
            sleep_time = retries * 100
            Process.sleep(sleep_time)

            # IO.inspect {"purerlex: likely file system race condition, sleeping for #{sleep_time}ms before retrying erlc call"}
            compile_erlang(source, module_name, logfile, retries + 1)

          true ->
            IO.puts("#############################################################################")
            IO.puts("####### Erl compiler failed to run; something has gone terribly wrong #######")
            IO.puts("#############################################################################")

            raise CompileError
        end
    end
    # IO.inspect({DateTime.diff(DateTime.utc_now(), st, :millisecond), source})

    case module_name do
      nil -> nil
      _ -> GenServer.cast(@name, {:erl_step_complete, module_name})
    end
  end

  def extract_purs_cmd(line) do
    split_str = "Running command: `purs compile"

    [_debug, args_with_end] = line |> String.split(split_str, parts: 2)
    [args, _end] = args_with_end |> String.split("`", parts: 2)
    # [drathier]: trim_leading to allow easier searching in logfiles
    {:ok, "purs compile " <> String.trim_leading(args, " ")}
  end

  def cache(logfile, cache_file, things) do
    db = Map.new()
    db = things |> List.foldl(db, fn x, acc -> merge(logfile, x, acc) end)

    warns = load_warning_cache(logfile, cache_file)

    ignore_mtime =
      not Enum.member?(["", "0", "false"], System.get_env("PURERLEX_IGNORE_MTIME", ""))

    merged =
      Map.merge(warns, db)
      |> Enum.map(fn {k, v} ->
        {k,
         v
         |> Enum.filter(fn thing ->
           # NOTE[et]: This isn't a perfect solution. If your texteditor `touches` your files having the file open might trigger a recompile. This means the cache now misses some warnings - but all warnings it shows are relevant. I think this is an improvement to what we had before where warnings *might* be relevant. I personally prefer this behavior.
           ignore_mtime ||
             case File.stat(Map.get(thing, "filename") || "dummy", [{:time, :posix}]) do
               # If the warning is from a compilation that started after the file was modified - we keep it
               {:ok, %{mtime: t}} ->
                 t <= DateTime.to_unix(thing.start_compile_at)

               # If we can't read it - no one else can either so just remove the warning to avoid false positives
               _ ->
                 false
             end
         end)}
      end)
      |> Map.new()

    store_warning_cache(cache_file, merged)

    # keys = merged |> Map.keys()
    # IO.inspect {:purserl_cache, keys, merged}
    merged
  end

  def del_cache(logfile, cache_file, key) do
    warns = load_warning_cache(logfile, cache_file)
    merged = warns |> Map.delete(key)
    store_warning_cache(cache_file, merged)

    # keys = merged |> Map.keys()
    # IO.inspect {:purserl_cache_del, key, keys, merged}
    merged
  end

  def load_warning_cache(_logfile, nil), do: %{}

  def load_warning_cache(logfile, path) do
    case File.read(path) do
      {:ok, ""} ->
        %{}

      {:ok, res} ->
        :erlang.binary_to_term(res)

      {:error, :enoent} ->
        %{}

      {:error, err} ->
        runtime_bug(logfile, {:purserl_load_warning_cache_file_error, err})
        %{}
    end
  end

  def store_warning_cache(nil, _), do: nil

  def store_warning_cache(path, things) do
    data = :erlang.term_to_binary(things)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, data)
  end

  def get_filename(logfile, thing) do
    module_from_first_span =
      thing |> Map.get("allSpans", nil) |> List.first(%{}) |> Map.get("name", nil)

    moduleName = Map.get(thing, "moduleName", nil) || module_from_first_span

    if moduleName != nil do
      moduleName
    else
      path = Map.get(thing, "filename", nil)

      try do
        path
        |> String.split("src/", parts: 2)
        # |> IO.inspect(label: "src/")
        |> (fn [_, a] -> a end).()
        |> String.split(".purs", parts: 2)
        # |> IO.inspect(label: ".purs")
        |> (fn [a, _] -> a end).()
        |> String.replace("/", ".")
      rescue
        e in FunctionClauseError ->
          runtime_bug(logfile, {:get_filename, e})
          # IO.inspect {:get_filename, thing, Map.keys(thing), module_from_first_span}
          "<missing-filename>"
      end
    end
  end

  def merge(logfile, thing, db) do
    name = get_filename(logfile, thing)
    # [drathier]: TODO hotfix while debugging, ignore all spago errors and warnings even in cache
    if name |> String.starts_with?(".spago") do
      db
    else
      existing = Map.get(db, name, [])
      Map.put(db, name, [thing] ++ existing)
    end
  end

  def warnings_to_string(state) do
    things = load_warning_cache(state.logfile, state.build_error_cache)
             |> Map.values()
             |> Enum.reduce([], fn a, b -> a ++ b end)
             |> Enum.uniq() # |> IO.inspect(label: "things3")

    {:ok, pid} = StringIO.open("")
    process_warnings_impl(state, things, :done, pid)
    {:ok, {_, output}} = StringIO.close(pid)
    String.trim(output)
  end

  def process_warnings(state), do: process_warnings(state, DateTime.utc_now(), [], [], :done)
  def process_warnings(state, start_compile_at, warnings, errors, done_or_wip) do
    things =
      (errors
       |> Enum.map(fn x ->
         x |> Map.put(:kind, :error) |> Map.put(:start_compile_at, start_compile_at)
       end)) ++
        (warnings
         |> Enum.map(fn x ->
           x |> Map.put(:kind, :warning) |> Map.put(:start_compile_at, start_compile_at)
         end))

    things2 = cache(state.logfile, state.build_error_cache, things)
    # |> IO.inspect(label: "things3")
    things3 = things2 |> Map.values() |> Enum.reduce([], fn a, b -> a ++ b end) |> Enum.uniq()

    case {state.build_error_cache, done_or_wip} do
      # [drathier]: build cache is disabled; print warnings as we go on :wip
      {nil, :wip} -> process_warnings_impl(state, things3, done_or_wip, :stderr)

      # [drathier]: build cache is enabled; store warnings, and we'll print them when the build is all :done
      {_build_error_cache, :done} -> process_warnings_impl(state, things3, done_or_wip, :stderr)
      {_build_error_cache, :wip} -> :wip
    end
  end

  def process_warnings_impl(state, things, done_or_wip, device) do
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
      things
      |> Enum.filter(fn x ->
        case x do
          %{"filename" => ".spago/" <> _} -> false
          # [fh]: we sometimes get null filenames from compiler; whyyyy?
          %{"filename" => nil} -> false
          _ -> true
        end
      end)
      |> Enum.map(fn x ->
        case x do
          %{
            "filename" => _filename,
            "position" => nil
          } ->
            Map.put(x, "position", %{
              "startColumn" => 0,
              "startLine" => 0,
              "endColumn" => 0,
              "endLine" => 0
            })

          _ ->
            x
        end
      end)
      |> Enum.sort_by(fn x ->
        %{
          "filename" => filename,
          "position" => %{
            "startColumn" => start_column,
            "startLine" => start_line,
            "endColumn" => end_column,
            "endLine" => end_line
          }
        } = x

        {error_kind_ord(state.logfile, x), filename, start_line, start_column, end_line,
         end_column}
      end)

    file_contents_map =
      not_in_spago
      |> Enum.map(fn x -> x["filename"] end)
      |> Enum.sort()
      |> Enum.dedup()
      |> List.foldl(%{}, fn filename, acc ->
        case Map.get(acc, filename) do
          nil ->
            case File.read(filename) do
              {:ok, content} ->
                Map.put(acc, filename, content)

              {:error, err} ->
                runtime_bug(
                  state.logfile,
                  {"Failed to read file contents when writing warning", filename, err}
                )

                ""
            end

          _ ->
            acc
        end
      end)

    with_file_contents =
      not_in_spago
      |> Enum.map(fn x -> Map.put(x, :file_contents_before, file_contents_map[x["filename"]]) end)

    should_be_fixed_automatically =
      if done_or_wip == :wip ||
           Enum.member?(["", "0", "false"], System.get_env("PURERLEX_FIX", "")) do
        []
      else
        with_file_contents
        |> Enum.filter(fn a -> can_be_fixed_automatically?(state.logfile, a) end)
      end

    reverse_sorted_applications =
      should_be_fixed_automatically
      |> Enum.sort_by(fn %{
                           "suggestion" => %{
                             "replaceRange" => %{
                               "startColumn" => start_column,
                               "startLine" => start_line,
                               "endColumn" => end_column,
                               "endLine" => end_line
                             }
                           }
                         } ->
        {start_line, start_column, end_line, end_column}
      end)
      |> Enum.reverse()

    reverse_sorted_applications
    |> Enum.map(fn x -> apply_suggestion(x, state) end)

    terse = not Enum.member?(["", "0", "false"], System.get_env("PURERLEX_TERSE", ""))

    to_print =
      with_file_contents
      |> Enum.flat_map(fn x ->
        case error_kind(state.logfile, x) do
          :ignore ->
            []

          :warn_msg ->
            []

          :warn_fixable ->
            [{x, format_warning_or_error(state, terse, :warn_fixable, x)}]

          :warn_no_autofix ->
            [{x, format_warning_or_error(state, terse, :warn_no_autofix, x)}]

          :error ->
            [{x, format_warning_or_error(state, terse, :error, x)}]
        end
      end)

    to_print_chunked =
      to_print
      |> Enum.chunk_by(fn {x, _} -> x["filename"] end)

    to_print_chunked
    |> List.foldl(nil, fn chunk, previous ->
      [{x, _} | _] = chunk

      xname = x["moduleName"] || x["filename"]
      rhs = " " <> xname <> " ====="

      IO.puts(device,
        cond do
          # NOTE[drathier]: tried to get some kind of delimiter between errors, but it was too noisy
          true ->
            ""

          previous == nil ->
            Color.magenta() <> mid_pad("=", "", rhs) <> Color.reset() <> "\n"

          previous != nil && x["filename"] != previous["filename"] ->
            Color.magenta() <> mid_pad("=", "", rhs) <> Color.reset() <> "\n"

          # Color.magenta() <> mid_pad("=", "===== " <> previousname <> " === ^^^ ", rhs) <> Color.reset() <> "\n"

          true ->
            ""
        end
      )

      chunk
      |> Enum.map(fn {_, text} -> text end)
      |> Enum.map(fn chunk ->
        log("print_err_warn_to_stdout", {chunk}, state.logfile)
        IO.puts(device, chunk)
      end)

      x
    end)
  end

  def mid_pad(pad, prefix, suffix) do
    count = 120 - String.length(prefix) - String.length(suffix)
    prefix <> String.duplicate(pad, max(10, count)) <> suffix
  end

  def format_warning_or_error(
        state,
        terse,
        kind,
        inp
      ) do
    case inp do
      %{
        # "allSpans" => [
        #  %{"end" => '$\f', "name" => "lib/Shell.purs", "start" => [36, 1]}
        # ],
        :file_contents_before => old_content,
        "allSpans" => all_spans,
        # "CycleInDeclaration"
        "errorCode" => error_code,
        "errorLink" => _,
        # "lib/Shell.purs"
        "filename" => filename,
        :kind => _,
        # "  The value of qwer is undefined here, so this reference is not allowed.\n"
        "message" => message,
        # nil
        "moduleName" => module_name,
        "position" => %{
          "endColumn" => _,
          "endLine" => _,
          "startColumn" => _,
          "startLine" => _
        },
        "suggestion" => _
      } ->
        modu = Color.magenta() <> (module_name || filename) <> Color.reset()

        max_lines_of_context =
          System.get_env("PURERLEX_MAX_LINES_OF_CONTEXT", "3")
          |> String.trim_trailing()
          |> String.to_integer()

        start_line =
          all_spans
          |> Enum.find_value(0, fn inp ->
            case inp do
              %{"start" => [start_line, _]} -> start_line
              _ -> nil
            end
          end)

        snippets =
          all_spans
          |> Enum.map(fn inp ->
            case inp do
              %{
                "name" => _,
                "start" => [start_line, start_column],
                "end" => [end_line, end_column]
              } ->
                snippet =
                  parse_out_span(%{
                    :file_contents_before => old_content,
                    :start_line => start_line,
                    :start_column => start_column,
                    :end_line => end_line,
                    :end_column => end_column
                  })

                snippet_context_pre =
                  ((snippet["prefix_lines"]
                    |> String.split("\n")
                    |> Enum.reverse()
                    |> Enum.take(state.ctx_lines_above)
                    |> Enum.reverse()
                    |> Enum.join("\n")) <>
                     snippet["prefix_columns"])
                  |> String.trim_leading("\n")

                snippet_actual =
                  snippet["infix_lines"] <>
                    snippet["infix_columns"]

                snippet_context_post =
                  (snippet["suffix_columns"] <>
                     (snippet["suffix_lines"]
                      |> String.split("\n")
                      |> Enum.take(state.ctx_lines_below)
                      |> Enum.join("\n")))
                  |> String.trim_trailing()

                common_prefix =
                  get_common_line_prefix(
                    snippet_context_pre <> snippet_actual <> snippet_context_post
                  )

                code_snippet_with_context =
                  ((snippet_context_pre
                    |> take_lines(-Integer.floor_div(max_lines_of_context, 2))
                    |> strip_prefix_all_lines(common_prefix)
                    |> prefix_all_lines(" ")) <>
                     (Color.yellow() <>
                        (snippet_actual
                         |> strip_prefix_all_lines(common_prefix)
                         |> prefix_lines_skipping_first(" ")) <> Color.reset()) <>
                     (snippet_context_post
                      |> strip_prefix_all_lines(common_prefix)
                      |> prefix_all_lines(" ")))
                  |> take_lines(max_lines_of_context)

                ("  " <> format_path_with_line(filename, start_line) <> "\n") <>
                  (code_snippet_with_context
                   |> prefix_all_lines(Color.yellow() <> "  | " <> Color.reset()))

              _ ->
                runtime_bug(
                  state.logfile,
                  {"###", "UNEXPECTED_SNIPPET_FORMAT",
                   "please post this dump to the purerlex developers at https://github.com/drathier/purerlex/issues/new",
                   kind, inp}
                )

                ""
            end
          end)

        tag =
          case kind do
            :warn_fixable ->
              if Enum.member?(["", "0", "false"], System.get_env("PURERLEX_FIX", "")) do
                Color.yellow() <> "Fixable" <> Color.reset()
              else
                Color.green() <> "Fixed" <> Color.reset()
              end

            :warn_no_autofix ->
              Color.yellow() <> "Warning" <> Color.reset()

            :error ->
              Color.red() <> "Error" <> Color.reset()

            _ ->
              runtime_bug(
                state.logfile,
                {"###", "UNEXPECTED_ERROR_KIND",
                 "please post this dump to the purerlex developers at https://github.com/drathier/purerlex/issues/new",
                 kind, inp}
              )

              ""
          end

        short_tag =
          case kind do
            :warn_fixable ->
              if Enum.member?(["", "0", "false"], System.get_env("PURERLEX_FIX", "")) do
                Color.yellow() <> "X" <> Color.reset()
              else
                Color.green() <> "F" <> Color.reset()
              end

            :warn_no_autofix ->
              Color.yellow() <> "W" <> Color.reset()

            :error ->
              Color.red() <> "E" <> Color.reset()

            _ ->
              runtime_bug(
                state.logfile,
                {"###", "UNEXPECTED_ERROR_KIND",
                 "please post this dump to the purerlex developers at https://github.com/drathier/purerlex/issues/new",
                 kind, inp}
              )

              ""
          end

        if terse do
          short_tag <>
            " " <>
            Color.cyan() <>
            error_code <> Color.reset() <> " " <> format_path_with_line(filename, start_line)
        else
          (Color.cyan() <>
             error_code <> Color.reset() <> " " <> tag <> " " <> modu <> "\n") <>
            "\n" <>
            Enum.join(snippets, "\n") <>
            "\n\n" <>
            (message |> add_prefix_if_missing("  ") |> syntax_highlight_indentex_lines("    ")) <>
            "\n"
        end

      _ ->
        runtime_bug(
          state.logfile,
          {"###", "UNEXPECTED_WARN_FORMAT",
           "please post this dump to the purerlex developers at https://github.com/drathier/purerlex/issues/new",
           kind, inp}
        )

        ""
    end
  end

  def get_common_line_prefix(things) when is_binary(things) do
    if things == "" do
      ""
    else
      get_common_line_prefix(things |> String.split("\n"))
    end
  end

  def get_common_line_prefix(things, count \\ 1) when is_list(things) do
    prefixes =
      things
      |> Enum.map(fn s -> String.slice(s, 0, count) end)
      # only looking at spaces here, to avoid dropping useful code
      |> Enum.filter(fn x -> String.trim_leading(x, " ") == "" end)
      |> length()

    case prefixes == length(things) do
      true ->
        get_common_line_prefix(things, count + 1)

      false ->
        [thing | _] = things
        String.slice(thing, 0, count - 1)
    end
  end

  def format_path_with_line(path, line) do
    Color.magenta() <>
      if line do
        path <> ":" <> "#{line}"
      else
        path
      end <>
      Color.reset()
  end

  def prefix_lines_skipping_first(str, prefix) do
    str
    |> String.split("\n")
    |> Enum.map(fn x -> prefix <> x end)
    |> Enum.join("\n")
    |> String.replace_prefix(prefix, "")
  end

  def take_lines(str, lines) do
    str
    |> String.split("\n")
    |> Enum.take(lines)
    |> Enum.join("\n")
  end

  def prefix_all_lines(str, prefix) do
    str
    |> String.split("\n")
    |> Enum.map(fn x -> prefix <> x end)
    |> Enum.join("\n")
  end

  def strip_prefix_all_lines(str, unwanted_prefix) do
    ("\n" <> str)
    |> String.replace("\n" <> unwanted_prefix, "\n")
    |> String.slice(1..-1//1)
  end

  def add_prefix_if_missing(str, prefix) do
    str
    |> String.split("\n")
    |> Enum.map(fn x ->
      cond do
        x |> String.starts_with?(prefix) ->
          x

        true ->
          prefix <> x
      end
    end)
    |> Enum.join("\n")
  end

  def syntax_highlight_indentex_lines(str, _prefix) do
    str
  end

  def syntax_highlight_indentex_lines2(str, prefix) do
    str
    |> String.split("\n")
    |> Enum.map(fn x ->
      cond do
        x |> String.starts_with?(prefix) ->
          prefixless = x |> String.trim_leading(prefix)
          prefix_row = x |> String.slice(0..(-String.length(prefixless) - 1))
          prefix_row <> hacky_syntax_highlight(x)

        true ->
          x
      end
    end)
    |> Enum.join("\n")
  end

  def hacky_syntax_highlight(str) do
    purescript_keywords = [
      "∀",
      "forall",
      "ado",
      "as",
      "case",
      "class",
      "data",
      "derive",
      "do",
      "else",
      "false",
      "foreign",
      "hiding",
      "import",
      "if",
      "in",
      "infix",
      "infixl",
      "infixr",
      "instance",
      "let",
      "module",
      "newtype",
      "nominal",
      "phantom",
      "of",
      "representational",
      "role",
      "then",
      "true",
      # "type", # false positives
      "where"
    ]

    purescript_infix_operator_characters =
      "!#€%&/()=?©@£$∞§|[]≈±¡”¥¢‰{}≠¿'*¨^<>-,:;\\"
      |> String.split("")
      |> Enum.filter(fn x -> x != "" end)

    tokenize(purescript_infix_operator_characters, str)
    |> Enum.filter(fn x -> x != "" end)
    |> Enum.map(fn x ->
      cond do
        Enum.member?(purescript_keywords, x) ->
          Color.yellow() <> x <> Color.reset()

        x
        |> String.split("")
        |> Enum.filter(fn c -> c != "" end)
        |> Enum.all?(fn c -> Enum.member?(purescript_infix_operator_characters, c) end) ->
          Color.magenta() <> x <> Color.reset()

        String.first(String.trim(x)) == "\"" ->
          Color.green() <> x <> Color.reset()

        String.first(x) == String.upcase(String.first(x)) ->
          Color.cyan() <> x <> Color.reset()

        true ->
          x
      end
    end)
    |> Enum.join("")
  end

  def tokenize(purescript_infix_operator_characters, str, kind \\ nil, curr \\ [], acc \\ []) do
    {next_kind, ch, rest} =
      case str do
        # enter quote
        <<"\"", rest::binary>> when kind != :quote ->
          {:quote, "\"", rest}

        <<"\"", rest::binary>> when kind != :quote ->
          {:quote, "\"", rest}

        # quoted strings and escape sequences
        <<"\\", c2::binary-size(1), rest::binary>> when kind == :quote ->
          {:quote, "\\" <> c2, rest}

        # end quote
        <<"\"", rest::binary>> when kind == :quote ->
          {:end_quote, "\"", rest}

        # non-quote
        <<c::binary-size(1)>> <> rest ->
          cond do
            kind == :quote ->
              {:quote, c, rest}

            # other
            c |> String.trim() != c ->
              {:space, c, rest}

            Enum.member?(purescript_infix_operator_characters, c) ->
              {:op, c, rest}

            true ->
              {:word, c, rest}
          end

        "" ->
          {:done, "", ""}
      end

    cond do
      curr == [] && next_kind == :done ->
        # all done
        Enum.reverse(acc) |> Enum.filter(fn c -> c != "" end)

      next_kind == :quote || next_kind == :end_quote ->
        # append to curr and move on
        tokenize(purescript_infix_operator_characters, rest, next_kind, [ch | curr], acc)

      next_kind == :done || next_kind != kind ->
        # move curr into acc
        tokenize(purescript_infix_operator_characters, str, next_kind, [], [
          Enum.reverse(curr) |> Enum.join("") | acc
        ])

      next_kind == kind ->
        # append to curr
        tokenize(purescript_infix_operator_characters, rest, next_kind, [ch | curr], acc)
    end
  end

  def parse_out_span(%{
        :file_contents_before => old_content,
        :start_line => start_line,
        :start_column => start_column,
        :end_line => end_line,
        :end_column => end_column
      }) do
    r_prefix_lines = "(?<prefix_lines>(([^\n]*\n){#{start_line - 1}}))"
    r_prefix_columns = "(?<prefix_columns>(.{#{start_column - 1}}))"
    r_infix_lines = "(?<infix_lines>(([^\n]*\n){#{end_line - start_line}}))"
    r_infix_columns = "(?<infix_columns>(.{#{end_column - start_column}}))"
    r_suffix_columns = "(?<suffix_columns>[^\n]*)"
    r_suffix_lines = "(?<suffix_lines>[\\S\\s]*)"

    r =
      r_prefix_lines <>
        r_prefix_columns <>
        r_infix_lines <>
        r_infix_columns <>
        r_suffix_columns <>
        r_suffix_lines

    case Regex.named_captures(Regex.compile!(r, [:unicode]), old_content) do
      nil ->
        %{
          "prefix_lines" => "",
          "prefix_columns" => "",
          "infix_lines" => "Failed to parse out error snippet",
          "infix_columns" => "",
          "suffix_columns" => "",
          "suffix_lines" => ""
        }

      v ->
        v
    end
  end

  def can_be_fixed_automatically?(logfile, x) do
    error_kind(logfile, x) == :warn_fixable
  end

  def error_kind_ord(logfile, x) do
    case error_kind(logfile, x) do
      :warn_msg ->
        1

      :ignore ->
        1

      :warn_fixable ->
        2

      :warn_no_autofix ->
        3

      :error ->
        4
    end
  end

  def error_kind(logfile, x) do
    # :ignore
    # :warn_fixable
    # :warn_no_autofix
    # :error
    case x do
      # warn fixable
      %{"errorCode" => "UnusedImport", "suggestion" => %{"replacement" => _replacement}} ->
        :warn_fixable

      %{"errorCode" => "DuplicateImport", "suggestion" => %{"replacement" => _replacement}} ->
        :warn_fixable

      %{"errorCode" => "UnusedExplicitImport", "suggestion" => %{"replacement" => _replacement}} ->
        :warn_fixable

      %{"errorCode" => "UnusedDctorImport", "suggestion" => %{"replacement" => _replacement}} ->
        :warn_fixable

      %{
        "errorCode" => "UnusedDctorExplicitImport",
        "suggestion" => %{"replacement" => _replacement}
      } ->
        :warn_fixable

      %{
        "errorCode" => "ImplicitQualifiedImport",
        "suggestion" => %{"replacement" => _replacement}
      } ->
        :ignore

      %{"errorCode" => "HidingImport", "suggestion" => %{"replacement" => _replacement}} ->
        :warn_fixable

      %{"errorCode" => "MissingTypeDeclaration", "suggestion" => %{"replacement" => _replacement}} ->
        :warn_fixable

      %{"errorCode" => "MissingKindDeclaration", "suggestion" => %{"replacement" => _replacement}} ->
        :warn_fixable

      %{"errorCode" => "WarningParsingModule", "suggestion" => %{"replacement" => _replacement}} ->
        :warn_fixable

      # suggestion is not always present for some reason
      %{"errorCode" => "UnusedTypeVar", "suggestion" => %{"replacement" => _replacement}} ->
        :warn_fixable

      %{"errorCode" => "UnusedTypeVar"} ->
        :warn_no_autofix

      %{"errorCode" => "UserDefinedWarning"} ->
        :warn_no_autofix

      %{"errorCode" => "UnusedDeclaration"} ->
        :warn_no_autofix

      %{"errorCode" => "UnusedFFIImplementations"} ->
        :warn_no_autofix

      %{"errorCode" => "UnusedName"} ->
        :warn_no_autofix

      %{"errorCode" => "MissingKindDeclaration"} ->
        :warn_no_autofix

      %{"errorCode" => "MissingNewtypeSuperclassInstance"} ->
        :warn_no_autofix

      %{"errorCode" => "MissingTypeDeclaration"} ->
        :warn_no_autofix

      %{"errorCode" => "ShadowedName"} ->
        :warn_no_autofix

      %{"errorCode" => "ImplicitImport", "suggestion" => %{"replacement" => replacement}} ->
        cond do
          replacement |> String.starts_with?("import Joe") ->
            :ignore

          replacement |> String.starts_with?("import Prelude") ->
            :ignore

          true ->
            :warn_no_autofix
        end

      # warn without autofix
      %{"errorCode" => "ScopeShadowing", "message" => message} ->
        cond do
          message |> String.contains?("import Joe") ->
            :ignore

          message |> String.contains?("import Prelude") ->
            :ignore

          true ->
            :warn_no_autofix
        end

      %{"errorCode" => "ShadowedTypeVar", "filename" => filename} ->
        cond do
          filename |> String.contains?("Data/Veither.purs") ->
            :ignore

          filename |> String.contains?("Vendor") ->
            :ignore

          true ->
            :warn_no_autofix
        end

      %{"errorCode" => "ImplicitQualifiedImportReExport"} ->
        :warn_no_autofix

      %{"errorCode" => "HiddenConstructors"} ->
        :ignore

      # ignored
      %{"errorCode" => "WildcardInferredType"} ->
        :ignore

      %{"errorCode" => "AdditionalProperty"} ->
        :error

      %{"errorCode" => "AmbiguousTypeVariables"} ->
        :error

      %{"errorCode" => "ArgListLengthsDiffer"} ->
        :error

      %{"errorCode" => "CannotDefinePrimModules"} ->
        :error

      %{"errorCode" => "CannotDerive"} ->
        :error

      %{"errorCode" => "CannotDeriveInvalidConstructorArg"} ->
        :error

      %{"errorCode" => "CannotDeriveNewtypeForData"} ->
        :error

      %{"errorCode" => "CannotFindDerivingType"} ->
        :error

      %{"errorCode" => "CannotGeneralizeRecursiveFunction"} ->
        :error

      %{"errorCode" => "CannotUseBindWithDo"} ->
        :error

      %{"errorCode" => "CaseBinderLengthDiffers"} ->
        :error

      %{"errorCode" => "ClassInstanceArityMismatch"} ->
        :error

      %{"errorCode" => "ConstrainedTypeUnified"} ->
        :error

      %{"errorCode" => "CycleInDeclaration"} ->
        :error

      %{"errorCode" => "CycleInKindDeclaration"} ->
        :error

      %{"errorCode" => "CycleInModules"} ->
        :error

      %{"errorCode" => "CycleInTypeClassDeclaration"} ->
        :error

      %{"errorCode" => "CycleInTypeSynonym"} ->
        :error

      %{"errorCode" => "DeclConflict"} ->
        :error

      %{"errorCode" => "DeprecatedFFICommonJSModule"} ->
        :error

      %{"errorCode" => "DeprecatedFFIPrime"} ->
        :error

      %{"errorCode" => "DuplicateExportRef"} ->
        :error

      %{"errorCode" => "DuplicateImport"} ->
        :error

      %{"errorCode" => "DuplicateImportRef"} ->
        :error

      %{"errorCode" => "DuplicateInstance"} ->
        :error

      %{"errorCode" => "DuplicateLabel"} ->
        :error

      %{"errorCode" => "DuplicateModule"} ->
        :error

      %{"errorCode" => "DuplicateRoleDeclaration"} ->
        :error

      %{"errorCode" => "DuplicateSelectiveImport"} ->
        :warn_no_autofix

      %{"errorCode" => "DuplicateTypeArgument"} ->
        :error

      %{"errorCode" => "DuplicateTypeClass"} ->
        :error

      %{"errorCode" => "DuplicateValueDeclaration"} ->
        :error

      %{"errorCode" => "ErrorParsingModule"} ->
        :error

      %{"errorCode" => "ErrorParsingFFIModule"} ->
        :error

      %{"errorCode" => "EscapedSkolem"} ->
        :error

      %{"errorCode" => "ExpectedType"} ->
        :error

      %{"errorCode" => "ExpectedTypeConstructor"} ->
        :error

      %{"errorCode" => "ExpectedWildcard"} ->
        :error

      %{"errorCode" => "ExportConflict"} ->
        :error

      %{"errorCode" => "ExprDoesNotHaveType"} ->
        :error

      %{"errorCode" => "ExtraneousClassMember"} ->
        :error

      %{"errorCode" => "FileIOError"} ->
        :error

      %{"errorCode" => "HidingImport"} ->
        :error

      %{"errorCode" => "HoleInferredType"} ->
        :error

      %{"errorCode" => "ImportHidingModule"} ->
        :error

      %{"errorCode" => "IncompleteExhaustivityCheck"} ->
        :error

      %{"errorCode" => "IncorrectAnonymousArgument"} ->
        :error

      %{"errorCode" => "IncorrectConstructorArity"} ->
        :error

      %{"errorCode" => "InfiniteKind"} ->
        :error

      %{"errorCode" => "InfiniteType"} ->
        :error

      %{"errorCode" => "IntOutOfRange"} ->
        :error

      %{"errorCode" => "InternalCompilerError"} ->
        :error

      %{"errorCode" => "InvalidCoercibleInstanceDeclaration"} ->
        :error

      %{"errorCode" => "InvalidDerivedInstance"} ->
        :error

      %{"errorCode" => "InvalidDoBind"} ->
        :error

      %{"errorCode" => "InvalidDoLet"} ->
        :error

      %{"errorCode" => "InvalidFFIIdentifier"} ->
        :error

      %{"errorCode" => "InvalidInstanceHead"} ->
        :error

      %{"errorCode" => "InvalidNewtype"} ->
        :error

      %{"errorCode" => "InvalidNewtypeInstance"} ->
        :error

      %{"errorCode" => "InvalidOperatorInBinder"} ->
        :error

      %{"errorCode" => "KindsDoNotUnify"} ->
        :error

      %{"errorCode" => "MissingClassMember"} ->
        :error

      %{"errorCode" => "MissingFFIImplementations"} ->
        :error

      %{"errorCode" => "MissingFFIModule"} ->
        :error

      %{"errorCode" => "MixedAssociativityError"} ->
        :error

      %{"errorCode" => "ModuleNotFound"} ->
        :error

      %{"errorCode" => "MultipleTypeOpFixities"} ->
        :error

      %{"errorCode" => "MultipleValueOpFixities"} ->
        :error

      %{"errorCode" => "NameIsUndefined"} ->
        :error

      %{"errorCode" => "NoInstanceFound"} ->
        :error

      %{"errorCode" => "NonAssociativeError"} ->
        :error

      %{"errorCode" => "OrphanInstance"} ->
        :error

      %{"errorCode" => "OrphanKindDeclaration"} ->
        :error

      %{"errorCode" => "OrphanRoleDeclaration"} ->
        :error

      %{"errorCode" => "OrphanTypeDeclaration"} ->
        :error

      %{"errorCode" => "OverlappingArgNames"} ->
        :error

      %{"errorCode" => "OverlappingInstances"} ->
        :error

      %{"errorCode" => "OverlappingNamesInLet"} ->
        :error

      %{"errorCode" => "OverlappingPattern"} ->
        :error

      %{"errorCode" => "PartiallyAppliedSynonym"} ->
        :error

      %{"errorCode" => "PossiblyInfiniteCoercibleInstance"} ->
        :error

      %{"errorCode" => "PossiblyInfiniteInstance"} ->
        :error

      %{"errorCode" => "PropertyIsMissing"} ->
        :error

      %{"errorCode" => "PurerlError"} ->
        :error

      %{"errorCode" => "QuantificationCheckFailureInKind"} ->
        :error

      %{"errorCode" => "QuantificationCheckFailureInType"} ->
        :error

      %{"errorCode" => "RedefinedIdent"} ->
        :error

      %{"errorCode" => "RoleDeclarationArityMismatch"} ->
        :error

      %{"errorCode" => "RoleMismatch"} ->
        :error

      %{"errorCode" => "ScopeConflict"} ->
        :error

      %{"errorCode" => "TransitiveDctorExportError"} ->
        :error

      %{"errorCode" => "TransitiveExportError"} ->
        :error

      %{"errorCode" => "TypesDoNotUnify"} ->
        :error

      %{"errorCode" => "TypeRowsDoNotUnify"} ->
        :error

      %{"errorCode" => "UndefinedTypeVariable"} ->
        :error

      %{"errorCode" => "UnknownClass"} ->
        :error

      %{"errorCode" => "UnknownExport"} ->
        :error

      %{"errorCode" => "UnknownExportDataConstructor"} ->
        :error

      %{"errorCode" => "UnknownImport"} ->
        :error

      %{"errorCode" => "UnknownImportDataConstructor"} ->
        :error

      %{"errorCode" => "UnknownName"} ->
        :error

      %{"errorCode" => "UnnecessaryFFIModule"} ->
        :error

      %{"errorCode" => "UnsupportedFFICommonJSExports"} ->
        :error

      %{"errorCode" => "UnsupportedFFICommonJSImports"} ->
        :error

      %{"errorCode" => "UnsupportedRoleDeclaration"} ->
        :error

      %{"errorCode" => "UnsupportedTypeInKind"} ->
        :error

      %{"errorCode" => "UnusableDeclaration"} ->
        :error

      %{"errorCode" => "UnverifiableSuperclassInstance"} ->
        :error

      %{"errorCode" => "VisibleQuantificationCheckFailureInType"} ->
        :error

      %{"errorCode" => "CannotApplyExpressionOfTypeOnType"} ->
        :error

      ###
      _ ->
        runtime_bug(
          logfile,
          {"###", "UNHANDLED_SUGGESTION_TAG",
           "please post this dump to the purerlex developers at https://github.com/drathier/purerlex/issues/new",
           x}
        )

        :warn_msg
    end
  end

  def runtime_bug(logfile, msg) do
    if logfile != nil do
      log("runtime_bug", msg, logfile)
    end

    IO.inspect(msg, width: :infinity, printable_limit: :infinity, limit: :infinity)
  end

  def apply_suggestion(
        %{
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
        } = inp,
        state
      ) do
    # NOTE[drathier]: we're reading the file contents back for each applied fix, so they all get applied. We could do them all in-memory, but this is easier to do. It's way past midnight.

    case File.read(filename) do
      {:ok, old_content} ->
        reg =
          parse_out_span(%{
            :file_contents_before => old_content,
            :start_line => start_line,
            :start_column => start_column,
            :end_line => end_line,
            :end_column => end_column
          })

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

        if new_content != old_content do
          log("apply_suggestion:applied", {inp}, state.logfile)

          case File.write(filename, new_content) do
            :ok ->
              nil

            {:error, err} ->
              runtime_bug(state.logfile, {"Failed to write file after auto-fix", filename, err})
          end

          :applied_suggestion
        else
          log("apply_suggestion:noop", {inp}, state.logfile)
          :no_change
        end

      {:error, err} ->
        runtime_bug(state.logfile, {"Failed to read file for auto-fix", filename, err})
        :error_reading_file
    end
  end

  defp await_task(t) do
    case Process.alive?(t) do
      true ->
        # IO.puts("Waiting for Erlang compilation to finish ...")
        ref = Process.monitor(t)
        receive do
          {:DOWN, ^ref, :process, ^t, :normal} -> :ok
        end
      false ->
        :ok
    end
  end

  defp await_tasks(state) do
    state.tasks
    |> Enum.map(fn t -> :ok = await_task(t) end)
    %{ state | tasks: [] }
  end

  defp print_elapsed(state) do
    ms = DateTime.diff(DateTime.utc_now(), state.started_at, :millisecond)
    IO.puts("Compilation took #{ms} ms")
  end

  defp reply(state, caller, response) do
    caller |> Enum.map(fn c -> GenServer.reply(c, response) end)
    {:noreply, %{state | caller: []}}
  end
end
