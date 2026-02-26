defmodule NetRunner.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {DynamicSupervisor, name: NetRunner.WatcherSupervisor, strategy: :one_for_one}
    ]

    opts = [strategy: :one_for_one, name: NetRunner.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
