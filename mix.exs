defmodule Purerlex.MixProject do
  use Mix.Project

  def project do
    [
      app: :purerlex,
      version: "0.1.0",
      elixir: "~> 1.12",
      start_permanent: Mix.env() == :prod,
      deps: deps(),

      # Docs
      name: "PurerlEx",
      source_url: "https://github.com/drathier/purerlex",
      homepage_url: "https://github.com/drathier/purerlex",
      docs: [
        #main: "PurerlEx", # The main page in the docs
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
      {:ex_doc, "~> 0.24", only: :dev}
    ]
  end
end
