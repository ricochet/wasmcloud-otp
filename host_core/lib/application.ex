defmodule HostCore.Application do
  @moduledoc """
  `HostCore` Application.
  """
  require Logger
  use Application

  @host_config_file "host_config.json"

  def start(_type, _args) do
    create_ets_tables()

    config = Vapor.load!(HostCore.Vhost.ConfigPlan)
    config = post_process_config(config)

    OpentelemetryLoggerMetadata.setup()

    children = mount_supervisor_tree(config)

    opts = [strategy: :one_for_one, name: HostCore.ApplicationSupervisor]

    started = Supervisor.start_link(children, opts)

    if config.enable_structured_logging do
      :logger.add_handler(:structured_logger, :logger_std_h, %{
        formatter: {HostCore.StructuredLogger.FormatterJson, []},
        level: config.structured_log_level,
        config: %{
          type: :standard_error
        }
      })

      :logger.remove_handler(Logger)
    end

    Logger.info(
      "Started wasmCloud OTP Host Runtime",
      version: "#{Application.spec(:host_core, :vsn) |> to_string()}"
    )

    started
  end

  def host_count() do
    Registry.count(Registry.HostRegistry)
  end

  # Returns [{host public key, <pid>, lattice_prefix}]
  @spec all_hosts() :: [{String.t(), pid(), String.t()}]
  def all_hosts() do
    Registry.select(Registry.HostRegistry, [
      {{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}
    ])
  end

  defp create_ets_tables() do
    :ets.new(:vhost_table, [:named_table, :set, :public])
    :ets.new(:policy_table, [:named_table, :set, :public])
    :ets.new(:module_cache, [:named_table, :set, :public])
  end

  defp mount_supervisor_tree(config) do
    [
      {Registry, keys: :unique, name: Registry.LatticeSupervisorRegistry},
      {Registry, keys: :duplicate, name: Registry.ProviderRegistry},
      {Registry, keys: :unique, name: Registry.HostRegistry},
      {Registry, keys: :duplicate, name: Registry.ActorRegistry},
      {Registry, keys: :unique, name: Registry.ActorRpcSubscribers},
      {Registry,
       keys: :duplicate,
       name: Registry.EventMonitorRegistry,
       partitions: System.schedulers_online()},
      {Phoenix.PubSub, name: :hostcore_pubsub},
      {Task.Supervisor, name: ControlInterfaceTaskSupervisor},
      {Task.Supervisor, name: InvocationTaskSupervisor},
      {HostCore.Actors.ActorRpcSupervisor, strategy: :one_for_one},
      {HostCore.Providers.ProviderSupervisor, strategy: :one_for_one, name: ProviderRoot},
      {HostCore.Actors.ActorSupervisor,
       strategy: :one_for_one,
       allow_latest: config.allow_latest,
       allowed_insecure: config.allowed_insecure},
      {HostCore.Actors.CallCounter, nil},
      {HostCore.Lattice.LatticeRoot, nil},
      {HostCore.Vhost.VirtualHost, config}
    ]
  end

  defp post_process_config(config) do
    {host_key, host_seed} =
      if config.host_seed == nil do
        HostCore.WasmCloud.Native.generate_key(:server)
      else
        case HostCore.WasmCloud.Native.pk_from_seed(config.host_seed) do
          {:ok, pk} ->
            {pk, config.host_seed}

          {:error, _err} ->
            Logger.error(
              "Failed to obtain host public key from seed: (#{config.host_seed}). Generating a new host key instead."
            )

            HostCore.WasmCloud.Native.generate_key(:server)
        end
      end

    config =
      config
      |> Map.put(:cluster_adhoc, false)
      |> Map.put(:cluster_key, "")
      |> Map.put(:host_key, host_key)
      |> Map.put(:host_seed, host_seed)

    s =
      Hashids.new(
        salt: "lc_deliver_inbox",
        min_len: 2
      )

    hid = Hashids.encode(s, Enum.random(1..4_294_967_295))
    config = Map.put(config, :cache_deliver_inbox, "_INBOX.#{hid}")

    if config.js_domain != nil && String.valid?(config.js_domain) &&
         String.length(config.js_domain) > 1 do
      Logger.info("Using JetStream domain: #{config.js_domain}", js_domain: "#{config.js_domain}")
    end

    {def_cluster_key, def_cluster_seed} = HostCore.WasmCloud.Native.generate_key(:cluster)

    chunk_config = %{
      "host" => config.rpc_host,
      "port" => "#{config.rpc_port}",
      "seed" => config.rpc_seed,
      "lattice" => config.lattice_prefix,
      "jwt" => config.rpc_jwt
    }

    chunk_config =
      if config.js_domain != nil do
        Map.put(chunk_config, "js_domain", config.js_domain)
      else
        chunk_config
      end

    case HostCore.WasmCloud.Native.set_chunking_connection_config(chunk_config) do
      :ok ->
        Logger.debug("Configured invocation chunking object store (NATS)")

      {:error, e} ->
        Logger.error(
          "Failed to configure invocation chunking object store (NATS): #{inspect(e)}. Any chunked invocations will fail."
        )
    end

    # we're generating the key, so we know this is going to work
    {:ok, issuer_key} = HostCore.WasmCloud.Native.pk_from_seed(def_cluster_seed)

    config =
      if config.cluster_seed == "" do
        %{
          config
          | cluster_seed: def_cluster_seed,
            cluster_key: def_cluster_key,
            cluster_issuers: [issuer_key],
            cluster_adhoc: true
        }
      else
        case HostCore.WasmCloud.Native.pk_from_seed(config.cluster_seed) do
          {:ok, pk} ->
            issuers = ensure_contains(config.cluster_issuers, pk)

            %{
              config
              | cluster_key: pk,
                cluster_issuers: issuers,
                cluster_adhoc: false
            }

          {:error, err} ->
            Logger.error(
              "Invalid cluster seed '#{config.cluster_seed}': #{err}, generating a new cluster seed instead."
            )

            %{
              config
              | cluster_seed: def_cluster_seed,
                cluster_key: def_cluster_key,
                cluster_issuers: [issuer_key],
                cluster_adhoc: true
            }
        end
      end

    write_config(config)

    config
  end

  defp write_config(config) do
    write_json(config, @host_config_file)

    case System.user_home() do
      nil ->
        Logger.warn(
          "Can't write ~/.wash/#{@host_config_file}: could not determine user's home directory."
        )

      h ->
        write_json(config, Path.join([h, "/.wash/", @host_config_file]))
    end
  end

  defp write_json(config, file) do
    with :ok <- File.mkdir_p(Path.dirname(file)) do
      case File.write(file, Jason.encode!(remove_extras(config))) do
        {:error, reason} -> Logger.error("Failed to write configuration file #{file}: #{reason}")
        :ok -> Logger.info("Wrote configuration file #{file}")
      end
    else
      {:error, posix} ->
        Logger.error("Failed to create path to config file #{file}: #{posix}")
    end
  end

  defp remove_extras(config) do
    config
    |> Map.delete(:cluster_adhoc)
    |> Map.delete(:cache_deliver_inbox)
    |> Map.delete(:host_seed)
    |> Map.delete(:enable_structured_logging)
    |> Map.delete(:structured_log_level)
    |> Map.delete(:host_key)
  end

  defp ensure_contains(list, item) do
    if Enum.member?(list, item) do
      list
    else
      [item | list]
    end
  end
end