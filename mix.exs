defmodule DistributedSupervisor.MixProject do
  use Mix.Project

  @app :distributed_supervisor
  @version "0.3.0"

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.14",
      compilers: compilers(Mix.env()),
      elixirc_paths: elixirc_paths(Mix.env()),
      consolidate_protocols: Mix.env() not in [:dev, :test],
      description: description(),
      package: package(),
      deps: deps(),
      aliases: aliases(),
      docs: docs(),
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        credo: :dev,
        dialyzer: :dev,
        tests: :test,
        "coveralls.json": :test,
        "coveralls.html": :test,
        "quality.ci": :dev
      ],
      releases: [],
      dialyzer: [
        plt_file: {:no_warn, ".dialyzer/dialyzer.plt"},
        plt_add_deps: :app_tree,
        plt_add_apps: [:mix],
        list_unused_filters: true,
        ignore_warnings: ".dialyzer/ignore.exs"
      ]
    ]
  end

  def application do
    [extra_applications: []]
  end

  defp deps do
    [
      {:libring, "~> 1.0"},
      {:nimble_options_ex, "~> 0.1"},
      {:doctest_formatter, "~> 0.2", only: [:dev], runtime: false},
      {:excoveralls, "~> 0.14", only: [:test], runtime: false},
      {:credo, "~> 1.0", only: [:dev, :test]},
      {:dialyxir, "~> 1.0", only: [:dev, :test], runtime: false},
      {:mneme, "~> 0.6", only: [:dev, :test]},
      {:ex_doc, ">= 0.0.0", only: [:dev]}
    ]
  end

  defp aliases do
    [
      quality: ["format", "credo --strict", "dialyzer"],
      "quality.ci": [
        "format --check-formatted",
        "credo --strict",
        "dialyzer"
      ]
    ]
  end

  defp description do
    """
    Distributed dynamic supervisor using `:pg` as a registry
    """
  end

  defp package do
    [
      name: @app,
      files: ~w|lib .formatter.exs .dialyzer/ignore.exs mix.exs README* LICENSE|,
      maintainers: ["Aleksei Matiushkin"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/am-kantox/#{@app}",
        "Docs" => "https://hexdocs.pm/#{@app}"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      canonical: "http://hexdocs.pm/#{@app}",
      logo: "stuff/#{@app}-48x48.png",
      source_url: "https://github.com/am-kantox/#{@app}",
      extras: ~w[README.md],
      groups_for_modules: [],
      groups_for_docs: [
        Interface: &(&1[:section] == :interface),
        Shenanigans: &(&1[:section] == :helpers)
      ]
    ]
  end

  defp elixirc_paths(:dev), do: ["lib", "test/support"]
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp compilers(_), do: Mix.compilers()
end
