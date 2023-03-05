defmodule DevHelpers.Purserl do
  use GenServer
  alias IO.ANSI, as: Color

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

    #IO.inspect({:init_purserl, config})

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
            process_warnings(v["warnings"], v["errors"])

            {:noreply, state}

          {:error, _} ->
            # nope, print it
            runtime_bug({"###", "FAILED_JSON_DECODE", "please post this dump to the purerlex developers at https://github.com/drathier/purerlex/issues/new", msg})
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

  def process_warnings(warnings, errors) do
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

    things =
      (errors |> Enum.map(fn x -> x |> Map.put(:kind, :error) end)) ++
        (warnings |> Enum.map(fn x -> x |> Map.put(:kind, :warning) end))

    not_in_spago =
      things
      |> Enum.filter(fn x ->
        case x do
          %{"filename" => ".spago/" <> _} -> false
          _ -> true
        end
      end)
      |> Enum.sort_by(fn x ->
        %{"filename" => filename, "position" => %{"startColumn" => start_column, "startLine" => start_line, "endColumn" => end_column, "endLine" => end_line}} = x
        {error_kind_ord(x), filename, start_line, start_column, end_line, end_column}
      end)

    file_contents_map =
      not_in_spago
      |> Enum.map(fn x -> x["filename"] end)
      |> Enum.sort()
      |> Enum.dedup()
      |> List.foldl(%{}, fn filename, acc ->
        case Map.get(acc, filename) do
          nil ->
            Map.put(acc, filename, File.read!(filename))

          _ ->
            acc
        end
      end)

    with_file_contents =
      not_in_spago
      |> Enum.map(fn x -> Map.put(x, :file_contents_before, file_contents_map[x["filename"]]) end)

    file_contents_map = nil

    should_be_fixed_automatically =
      with_file_contents
      |> Enum.filter(&can_be_fixed_automatically?/1)

    reverse_sorted_applications =
      should_be_fixed_automatically
      |> Enum.sort_by(fn %{"suggestion" => %{"replaceRange" => %{"startColumn" => start_column, "startLine" => start_line, "endColumn" => end_column, "endLine" => end_line}}} ->
        {start_line, start_column, end_line, end_column}
      end)
      |> Enum.reverse()

    reverse_sorted_applications
    |> Enum.map(fn x -> apply_suggestion(x) end)

    to_print =
      with_file_contents
      |> Enum.flat_map(fn x ->
        case error_kind(x) do
          :ignore ->
            []

          :warn_msg ->
            []

          :warn_fixable ->
            [{x, format_warning_or_error(:warn_fixable, x)}]

          :warn_no_autofix ->
            [{x, format_warning_or_error(:warn_no_autofix, x)}]

          :error ->
            [{x, format_warning_or_error(:error, x)}]
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
      cond do
        # NOTE[drathier]: tried to get some kind of delimiter between errors, but it was too noisy
        true -> ""

        previous == nil ->
          Color.magenta() <> mid_pad("=", "", rhs) <> Color.reset() <> "\n"

        previous != nil && x["filename"] != previous["filename"] ->
          previousname = previous["moduleName"] || previous["filename"]
          Color.magenta() <> mid_pad("=", "", rhs) <> Color.reset() <> "\n"
          #Color.magenta() <> mid_pad("=", "===== " <> previousname <> " === ^^^ ", rhs) <> Color.reset() <> "\n"

        true ->
          ""
      end
      |> IO.puts()

      chunk
      |> Enum.map(fn {_, text} -> text end)
      |> Enum.map(&IO.puts/1)

      x
    end)
  end

  def mid_pad(pad, prefix, suffix) do
    count = 120 - String.length(prefix) - String.length(suffix)
    prefix <> String.duplicate(pad, max(10, count)) <> suffix
  end

  def format_warning_or_error(
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
          "startLine" => start_line
        },
        "suggestion" => _
      } ->
        modu = module_name || filename

        modu_with_line = format_modu_with_line(modu, start_line)

        lines_of_context = 5

        snippets =
          all_spans
          |> Enum.map(fn inp ->
            case inp do
              %{"name" => _, "start" => [start_line, start_column], "end" => [end_line, end_column]} ->
                snippet =
                  parse_out_span(%{
                    :file_contents_before => old_content,
                    :start_line => start_line,
                    :start_column => start_column,
                    :end_line => end_line,
                    :end_column => end_column
                  })

                snippet_context_pre =
                  ((snippet["prefix_lines"] |> String.split("\n") |> Enum.reverse() |> Enum.take(lines_of_context) |> Enum.reverse() |> Enum.join("\n")) <>
                     snippet["prefix_columns"])
                  |> String.trim_leading()

                snippet_actual =
                  snippet["infix_lines"] <>
                    snippet["infix_columns"]

                snippet_context_post =
                  (snippet["suffix_columns"] <>
                     (snippet["suffix_lines"] |> String.split("\n") |> Enum.take(lines_of_context) |> Enum.join("\n")))
                  |> String.trim_trailing()

                code_snippet_with_context =
                  (snippet_context_pre |> prefix_all_lines(" ")) <>
                    (Color.yellow() <> (snippet_actual |> prefix_lines_skipping_first(" ")) <> Color.reset()) <>
                    (snippet_context_post |> prefix_all_lines(" "))

                ("  " <> format_modu_with_line(modu, start_line) <> "\n") <>
                  (code_snippet_with_context |> prefix_all_lines(Color.yellow() <> "  | " <> Color.reset()))

              _ ->
                runtime_bug({"###", "UNEXPECTED_SNIPPET_FORMAT", "please post this dump to the purerlex developers at https://github.com/drathier/purerlex/issues/new", kind, inp})
                ""
            end
          end)

        tag =
          case kind do
            :warn_fixable ->
              Color.green() <> "Fixed" <> Color.reset()

            :warn_no_autofix ->
              Color.yellow() <> "Warning" <> Color.reset()

            :error ->
              Color.red() <> "Error" <> Color.reset()

            _ ->
              runtime_bug({"###", "UNEXPECTED_ERROR_KIND", "please post this dump to the purerlex developers at https://github.com/drathier/purerlex/issues/new", kind, inp})
              ""
          end

        (Color.cyan() <> error_code <> Color.reset() <> " " <> tag <> " " <> modu_with_line <> "\n") <>
          "\n" <>
          ((message |> add_prefix_if_missing("  ") |> syntax_highlight_indentex_lines("    ")) <> "\n") <>
          Enum.join(snippets, "\n\n") <>
          "\n\n"

      _ ->
        runtime_bug({"###", "UNEXPECTED_WARN_FORMAT", "please post this dump to the purerlex developers at https://github.com/drathier/purerlex/issues/new", kind, inp})
        ""
    end
  end

  def format_modu_with_line(modu, line) do
    Color.magenta() <>
      if line do
        modu <> ":" <> "#{line}"
      else
        modu
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

  def prefix_all_lines(str, prefix) do
    str
    |> String.split("\n")
    |> Enum.map(fn x -> prefix <> x end)
    |> Enum.join("\n")
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

  def syntax_highlight_indentex_lines(str, prefix) do
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

        x |> String.split("") |> Enum.filter(fn c -> c != "" end) |> Enum.all?(fn c -> Enum.member?(purescript_infix_operator_characters, c) end) ->
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
        tokenize(purescript_infix_operator_characters, str, next_kind, [], [Enum.reverse(curr) |> Enum.join("") | acc])

      next_kind == kind ->
        # append to curr
        tokenize(purescript_infix_operator_characters, rest, next_kind, [ch | curr], acc)
    end
  end

  def parse_out_span(
        %{
          :file_contents_before => old_content,
          :start_line => start_line,
          :start_column => start_column,
          :end_line => end_line,
          :end_column => end_column
        } = inp
      ) do
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

    reg = Regex.named_captures(Regex.compile!(r), old_content)
    reg
  end

  def can_be_fixed_automatically?(x) do
    error_kind(x) == :warn_fixable
  end

  def error_kind_ord(x) do
    case error_kind(x) do
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

  def error_kind(x) do
    # :ignore
    # :warn_fixable
    # :warn_no_autofix
    # :error
    case x do
      # warn fixable
      %{"errorCode" => "UnusedImport", "suggestion" => %{"replacement" => replacement}} ->
        :warn_fixable

      %{"errorCode" => "DuplicateImport", "suggestion" => %{"replacement" => replacement}} ->
        :warn_fixable

      %{"errorCode" => "UnusedExplicitImport", "suggestion" => %{"replacement" => replacement}} ->
        :warn_fixable

      %{"errorCode" => "UnusedDctorImport", "suggestion" => %{"replacement" => replacement}} ->
        :warn_fixable

      %{"errorCode" => "UnusedDctorExplicitImport", "suggestion" => %{"replacement" => replacement}} ->
        :warn_fixable

      %{"errorCode" => "ImplicitQualifiedImport", "suggestion" => %{"replacement" => replacement}} ->
        :ignore

      %{"errorCode" => "HidingImport", "suggestion" => %{"replacement" => replacement}} ->
        :warn_fixable

      %{"errorCode" => "MissingTypeDeclaration", "suggestion" => %{"replacement" => replacement}} ->
        :warn_fixable

      %{"errorCode" => "MissingKindDeclaration", "suggestion" => %{"replacement" => replacement}} ->
        :warn_fixable

      %{"errorCode" => "WarningParsingCSTModule", "suggestion" => %{"replacement" => replacement}} ->
        :warn_fixable

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

      # errors
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
        :error

      %{"errorCode" => "DuplicateTypeArgument"} ->
        :error

      %{"errorCode" => "DuplicateTypeClass"} ->
        :error

      %{"errorCode" => "DuplicateValueDeclaration"} ->
        :error

      %{"errorCode" => "ErrorParsingCSTModule"} ->
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

      %{"errorCode" => "ImplicitQualifiedImportReExport"} ->
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

      %{"errorCode" => "MissingKindDeclaration"} ->
        :error

      %{"errorCode" => "MissingNewtypeSuperclassInstance"} ->
        :error

      %{"errorCode" => "MissingTypeDeclaration"} ->
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

      %{"errorCode" => "ShadowedName"} ->
        :error

      %{"errorCode" => "TransitiveDctorExportError"} ->
        :error

      %{"errorCode" => "TransitiveExportError"} ->
        :error

      %{"errorCode" => "TypesDoNotUnify"} ->
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

      %{"errorCode" => "UnusedDctorExplicitImport"} ->
        :error

      %{"errorCode" => "UnusedDctorImport"} ->
        :error

      %{"errorCode" => "UnusedDeclaration"} ->
        :error

      %{"errorCode" => "UnusedExplicitImport"} ->
        :error

      %{"errorCode" => "UnusedFFIImplementations"} ->
        :error

      %{"errorCode" => "UnusedImport"} ->
        :error

      %{"errorCode" => "UnusedName"} ->
        :error

      %{"errorCode" => "UnusedTypeVar"} ->
        :error

      %{"errorCode" => "UnverifiableSuperclassInstance"} ->
        :error

      %{"errorCode" => "UserDefinedWarning"} ->
        :error

      %{"errorCode" => "VisibleQuantificationCheckFailureInType"} ->
        :error

      %{"errorCode" => "WarningParsingCSTModule"} ->
        :error

      %{"errorCode" => "WildcardInferredType"} ->
        :error

      %{"errorCode" => "ErrorParsingModule"} ->
        :error

      ###
      _ ->
        runtime_bug({"###", "UNHANDLED_SUGGESTION_TAG", "please post this dump to the purerlex developers at https://github.com/drathier/purerlex/issues/new", x})
        :warn_msg
    end
  end

  def runtime_bug(msg) do
    IO.inspect(msg, width: :infinity, printable_limit: :infinity, limit: :infinity)
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
    # NOTE[drathier]: we're reading the file contents back for each applied fix, so they all get applied. We could do them all in-memory, but this is easier to do. It's way past midnight.
    old_content = File.read!(filename)

    reg =
      parse_out_span(%{
        :file_contents_before => old_content,
        :start_line => start_line,
        :start_column => start_column,
        :end_line => end_line,
        :end_column => end_column
      })

    # IO.inspect({"applying suggestion", filename, replacement})

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
