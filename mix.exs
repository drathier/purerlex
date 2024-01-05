defmodule Purerlex.MixProject do
  use Mix.Project

  def project do
    [
      app: :purerlex,
      version: "0.11.4",
      elixir: "~> 1.11",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      description:
        "PurerlEx allows you to automatically compile purerl code with mix, both in `mix compile` and with `recompile` in `iex -S mix`.",
      name: "PurerlEx",
      source_url: "https://github.com/drathier/purerlex",
      homepage_url: "https://github.com/drathier/purerlex",
      docs: [
        # The main page in the docs
        main: "Purerlex",
        extras: ["README.md"]
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_doc, "~> 0.24", only: :dev},
      {:jason, "~> 1.0"}
    ]
  end

  defp package do
    [
      files: ["lib", "mix.exs", "README*", "LICENSE*"],
      maintainers: ["drathier"],
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/drathier/purerlex"}
    ]
  end
end
