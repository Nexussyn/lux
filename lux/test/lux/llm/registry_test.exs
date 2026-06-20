defmodule Lux.LLM.RegistryTest do
  @moduledoc """
  Tests for the Lux.LLM.Registry module.

  Verifies provider registration, lookup, health status management,
  and listing functionality.
  """

  use ExUnit.Case, async: false

  alias Lux.LLM.Registry

  # Mock provider module for testing
  defmodule MockProvider do
    @behaviour Lux.LLM.Provider

    @impl true
    def name, do: :mock_provider

    @impl true
    def default_config do
      %{
        name: :mock_provider,
        api_key: nil,
        base_url: "https://api.mock.com",
        timeout: 30_000,
        max_retries: 3,
        models: [
          %{
            id: "mock-model-1",
            name: "Mock Model 1",
            capabilities: [:chat, :completion],
            context_window: 4096,
            max_output_tokens: 2048,
            cost_per_input_token: 0.001,
            cost_per_output_token: 0.002,
            supports_streaming: true,
            supports_functions: false,
            supports_vision: false
          }
        ],
        metadata: %{}
      }
    end

    @impl true
    def validate_config(_config), do: :ok

    @impl true
    def complete(_request, _config) do
      {:ok, %{
        id: "mock-response-1",
        provider: :mock_provider,
        model: "mock-model-1",
        choices: [
          %{
            index: 0,
            message: %{role: :assistant, content: "Hello!", name: nil, function_call: nil},
            finish_reason: :stop
          }
        ],
        usage: %{prompt_tokens: 10, completion_tokens: 5, total_tokens: 15},
        created_at: DateTime.utc_now(),
        metadata: %{}
      }}
    end

    @impl true
    def stream(_request, _config) do
      stream = Stream.map(["Hello", " ", "World"], fn text ->
        %{
          chunk: text,
          done: false
        }
      end)
      {:ok, stream}
    end

    @impl true
    def list_models(_config) do
      {:ok, [
        %{
          id: "mock-model-1",
          name: "Mock Model 1",
          capabilities: [:chat, :completion],
          context_window: 4096,
          max_output_tokens: 2048,
          cost_per_input_token: 0.001,
          cost_per_output_token: 0.002,
          supports_streaming: true,
          supports_functions: false,
          supports_vision: false
        }
      ]}
    end

    @impl true
    def embed(_input, _config) do
      {:ok, %{embeddings: [[0.1, 0.2, 0.3]], model: "mock-model-1", usage: %{total_tokens: 5}}}
    end
  end

  # Another mock provider for testing multiple registrations
  defmodule AnotherMockProvider do
    @behaviour Lux.LLM.Provider

    @impl true
    def name, do: :another_mock

    @impl true
    def default_config do
      %{
        name: :another_mock,
        api_key: nil,
        base_url: "https://api.another.com",
        timeout: 60_000,
        max_retries: 5,
        models: [],
        metadata: %{}
      }
    end

    @impl true
    def validate_config(_config), do: :ok

    @impl true
    def complete(_request, _config), do: {:error, :not_implemented}

    @impl true
    def stream(_request, _config), do: {:error, :not_implemented}

    @impl true
    def list_models(_config), do: {:ok, []}

    @impl true
    def embed(_input, _config), do: {:error, :not_implemented}
  end

  setup do
    # Start a fresh registry for each test
    registry_name = :"registry_test_#{System.unique_integer([:positive])}"
    {:ok, pid} = Registry.start_link(name: registry_name)

    on_exit(fn) ->
      if Process.alive?(pid) do
        GenServer.stop(pid)
      end
    end)

    {:ok, registry: registry_name}
  end

  describe "start_link/1" do
    test "starts the registry with default name" do
      name = :"test_registry_#{System.unique_integer([:positive])}"
      assert {:ok, pid} = Registry.start_link(name: name)
      assert is_pid(pid)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "starts the registry with custom name" do
      custom_name = :my_custom_registry
      assert {:ok, pid} = Registry.start_link(name: custom_name)
      assert is_pid(pid)
      assert Process.whereis(custom_name) == pid
      GenServer.stop(pid)
    end
  end

  describe "register/3/4" do
    test "registers a provider successfully", %{registry: registry} do
      assert :ok = Registry.register(:mock_provider, MockProvider, %{}, registry)
    end

    test "registers a provider with custom config", %{registry: registry} do
      custom_config = %{api_key: "test-key", timeout: 60_000}
      assert :ok = Registry.register(:mock_provider, MockProvider, custom_config, registry)
    end

    test "returns error when registering duplicate provider", %{registry: registry} do
      assert :ok = Registry.register(:mock_provider, MockProvider, %{}, registry)
      assert {:error, :already_registered} = Registry.register(:mock_provider, MockProvider, %{}, registry)
    end

    test "can register multiple different providers", %{registry: registry} do
      assert :ok = Registry.register(:mock_provider, MockProvider, %{}, registry)
      assert :ok = Registry.register(:another_mock, AnotherMockProvider, %{}, registry)
    end
  end

  describe "unregister/1/2" do
    test "unregisters an existing provider", %{registry: registry} do
      assert :ok = Registry.register(:mock_provider, MockProvider, %{}, registry)
      assert :ok = Registry.unregister(:mock_provider, registry)
      assert {:error, :not_found} = Registry.lookup(:mock_provider, registry)
    end

    test "returns error when unregistering non-existent provider", %{registry: registry} do
      assert {:error, :not_found} = Registry.unregister(:nonexistent, registry)
    end
  end

  describe "lookup/1/2" do
    test "looks up a registered provider", %{registry: registry} do
      assert :ok = Registry.register(:mock_provider, MockProvider, %{}, registry)
      assert {:ok, {module, config}} = Registry.lookup(:mock_provider, registry)
      assert module == MockProvider
      assert is_map(config)
    end

    test "returns error for non-existent provider", %{registry: registry} do
      assert {:error, :not_found} = Registry.lookup(:nonexistent, registry)
    end

    test "returns merged config with custom values", %{registry: registry} do
      custom_config = %{api_key: "my-api-key", timeout: 45_000}
      assert :ok = Registry.register(:mock_provider, MockProvider, custom_config, registry)
      assert {:ok, {_module, config}} = Registry.lookup(:mock_provider, registry)
      assert config.api_key == "my-api-key"
      assert config.timeout == 45_000
    end
  end

  describe "list_providers/0" do
    test "returns empty list when no providers registered", %{registry: registry} do
      assert [] == Registry.list_providers(registry)
    end

    test "returns all registered providers", %{registry: registry} do
      assert :ok = Registry.register(:mock_provider, MockProvider, %{}, registry)
      assert :ok = Registry.register(:another_mock, AnotherMockProvider, %{}, registry)

      providers = Registry.list_providers(registry)
      assert length(providers) == 2
      assert :mock_provider in providers
      assert :another_mock in providers
    end
  end

  describe "set_health_status/2/3" do
    test "sets health status to healthy", %{registry: registry} do
      assert :ok = Registry.register(:mock_provider, MockProvider, %{}, registry)
      assert :ok = Registry.set_health_status(:mock_provider, :healthy, registry)
    end

    test "sets health status to degraded", %{registry: registry} do
      assert :ok = Registry.register(:mock_provider, MockProvider, %{}, registry)
      assert :ok = Registry.set_health_status(:mock_provider, :degraded, registry)
    end

    test "sets health status to unhealthy", %{registry: registry} do
      assert :ok = Registry.register(:mock_provider, MockProvider, %{}, registry)
      assert :ok = Registry.set_health_status(:mock_provider, :unhealthy, registry)
    end

    test "returns error for non-existent provider", %{registry: registry} do
      assert {:error, :not_found} = Registry.set_health_status(:nonexistent, :healthy, registry)
    end
  end

  describe "get_health_status/1/2" do
    test "returns default healthy status for new provider", %{registry: registry} do
      assert :ok = Registry.register(:mock_provider, MockProvider, %{}, registry)
      assert {:ok, :healthy} = Registry.get_health_status(:mock_provider, registry)
    end

    test "returns updated health status", %{registry: registry} do
      assert :ok = Registry.register(:mock_provider, MockProvider, %{}, registry)
      assert :ok = Registry.set_health_status(:mock_provider, :degraded, registry)
      assert {:ok, :degraded} = Registry.get_health_status(:mock_provider, registry)
    end

    test "returns error for non-existent provider", %{registry: registry} do
      assert {:error, :not_found} = Registry.get_health_status(:nonexistent, registry)
    end
  end

  describe "healthy_providers/0" do
    test "returns only healthy providers", %{registry: registry} do
      assert :ok = Registry.register(:mock_provider, MockProvider, %{}, registry)
      assert :ok = Registry.register(:another_mock, AnotherMockProvider, %{}, registry)

      # Set one provider as unhealthy
      assert :ok = Registry.set_health_status(:another_mock, :unhealthy, registry)

      healthy = Registry.healthy_providers(registry)
      assert length(healthy) == 1
      assert :mock_provider in healthy
      refute :another_mock in healthy
    end

    test "includes degraded providers as healthy", %{registry: registry} do
      assert :ok = Registry.register(:mock_provider, MockProvider, %{}, registry)
      assert :ok = Registry.set_health_status(:mock_provider, :degraded, registry)

      healthy = Registry.healthy_providers(registry)
      assert :mock_provider in healthy
    end

    test "returns empty list when all unhealthy", %{registry: registry} do
      assert :ok = Registry.register(:mock_provider, MockProvider, %{}, registry)
      assert :ok = Registry.set_health_status(:mock_provider, :unhealthy, registry)

      assert [] == Registry.healthy_providers(registry)
    end
  end

  describe "update_config/2/3" do
    test "updates provider configuration", %{registry: registry} do
      assert :ok = Registry.register(:mock_provider, MockProvider, %{}, registry)

      new_config = %{api_key: "new-key", timeout: 120_000}
      assert :ok = Registry.update_config(:mock_provider, new_config, registry)

      assert {:ok, {_module, config}} = Registry.lookup(:mock_provider, registry)
      assert config.api_key == "new-key"
      assert config.timeout == 120_000
    end

    test "returns error for non-existent provider", %{registry: registry} do
      assert {:error, :not_found} = Registry.update_config(:nonexistent, %{}, registry)
    end
  end

  describe "get_provider_info/1/2" do
    test "returns full provider information", %{registry: registry} do
      assert :ok = Registry.register(:mock_provider, MockProvider, %{}, registry)

      assert {:ok, info} = Registry.get_provider_info(:mock_provider, registry)
      assert info.name == :mock_provider
      assert info.module == MockProvider
      assert is_map(info.config)
      assert info.health_status == :healthy
    end

    test "returns error for non-existent provider", %{registry: registry} do
      assert {:error, :not_found} = Registry.get_provider_info(:nonexistent, registry)
    end
  end
end