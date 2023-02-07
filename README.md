# Purerlex

PurerlEx allows you to automatically compile purerl code with mix, both in `mix compile` and with `recompile` in `iex -S mix`.

## Assumptions:
- All your non-dependency source files are in `src/**/*.purs`, `lib/**/*.purs` and/or `test/**/*.purs` relative to your `mix.exs`. These are the only places we look for changed files in (via mtime).
- Your spago build outputs files in the `output` folder in the project root.
- Your spago project is in the root of the mix project (`mix.exs` and `spago.dhall` are in the same folder, not in sub-folders).
- You have `spago` on your path.

## Installation

First install it by adding `purerlex` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:purerlex, "~> 0.5.0"}
  ]
end
```

Then run `mix deps.get` in your console to fetch from Hex

Then add the `:purerl` compiler to (the beginning of) the list of compilers and add `"output"` to the `erlc_paths`:

    def project do
      [
        ...
        erlc_paths: ["output"], # purerl
        compilers: [:purerl] ++ Mix.compilers(),
        ...
      ]
    end

Optionally, for dev builds, you can add the `:purserl` compiler instead and run a faster compiler fork from https://github.com/drathier/purserl/ .

Docs are also available at [https://hexdocs.pm/purerlex](https://hexdocs.pm/purerlex).

