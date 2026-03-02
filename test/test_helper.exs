exclude =
  case :os.type() do
    {:unix, :linux} -> []
    _ -> [:linux_only]
  end

ExUnit.start(exclude: exclude)
