defmodule Lux.LLM.FallbackChainTest do
  @moduledoc """
  Tests for the Lux.LLM.FallbackChain module.

  Verifies fallback behavior, circuit breaker integration,
  retry logic, and provider chain management.
  """

  use ExUnit.Case, async: false

  alias Lux.LLM.FallbackChain

  # Mock provider that always succeeds
  defmodule SuccessProvider do
    @behaviour Lux.LLM.Provider

    @impl true
    def name, do: :success_provider

    @impl true
    def default_config do
      %{
        name: :success_provider,
        api_key: "test-key",
        base_url: "https://api.success.com",
        timeout: 30_000,
        max_retries: 3,
        models: [
          %{
            id: "success-model",
            name: "Success Model",
            capabilities: [:chat, :completion],
            context_window: 4096,
            max_output_tokens: 2048,
            cost_per_input_token: 0.001,
            cost_per_output_token: 0.002,
            supports_streaming: true,
            supports_functions: true,
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
      {:ok,
       %{
         id: "success-response-123",
         provider: :success_provider,
         model: "success-model",
         choices: [
           %{
             index: 0,
             message: %{role: :assistant, content: "Success response", name: nil, function_call: nil},
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
      stream = Stream.map(["Success"], fn chunk ->
        %{delta: %{content: chunk}, finish_reason: :stop}
      end)
      {:ok, stream}
    end

    @impl true
    def embed(_input, _config), do: {:ok, %{
      embeddings: [[0.1, 0.2, 0.3]],
      model: "success-model",
      usage: %{prompt_tokens: 5, total_tokens: 5}
    }}

    @impl true
    def list_models(_config), do: {:ok, default_config().models}

    @impl true
    def health_check(_config), do: {:ok, :healthy}
  end

  # Mock provider that always fails
  defmodule FailingProvider do
    @behaviour Lux.LLM.Provider

    @impl true
    def name, do: :failing_provider

    @impl true
    def default_config do
      %{
        name: :failing_provider,
        api_key: "test-key",
        base_url: "https://api.failing.com",
        timeout: 30_000,
        max_retries: 3,
        models: [
          %{
            id: "failing-model",
            name: "Failing Model",
            capabilities: [:chat, :completion],
            context_window: 4096,
            max_output_tokens: 2048,
            cost_per_input_token: 0.001,
            cost_per_output_token: 0.002,
            supports_streaming: true,
            supports_functions: true,
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
      {:error, %{reason: :api_error, message: "Simulated failure", retryable: true}}
    end

    @impl true
    def stream(_request, _config) do
      {:error, %{reason: :api_error, message: "Simulated stream failure", retryable: true}}
    end

    @impl true
    def embed(_input, _config) do
      {:error, %{reason: :api_error, message: "Simulated embed failure", retryable: true}}
    end

    @impl true
    def list_models(_config), do: {:ok, default_config().models}

    @impl true
    def health_check(_config), do: {:error, :unhealthy}
  end

  # Mock provider that fails on first attempts then succeeds
  defmodule FlakyProvider do
    @behaviour Lux.LLM.Provider

    use Agent

    def start_link(_opts \\ []) do
      Agent.start_link(fn() -> 0 end, name: __MODULE__)
    end

    def reset do
      if Process.whereis(__MODULE__) do
        Agent.update(__MODULE__, fn (_) -> 0 end)
      end
    end

    def get_attempt_count do
      if Process.whereis(__MODULE__) do
        Agent.get(__MODULE__, & &1)
      else
        0
      end
    end

    defp increment_attempts do
      if Process.whereis(__MODULE__) do
        Agent.get_and_update(__MODULE__, fn count -> {count + 1, count + 1} end)
      else
        1
      end
    end

    @impl true
    def name, do: :flaky_provider

    @impl true
    def default_config do
      %{
        name: :flaky_provider,
        api_key: "test-key",
        base_url: "https://api.flaky.com",
        timeout: 30_000,
        max_retries: 3,
        models: [
          %{
            id: "flaky-model",
            name: "Flaky Model",
            capabilities: [:chat, :completion],
            context_window: 4096,
            max_output_tokens: 2048,
            cost_per_input_token: 0.001,
            cost_per_output_token: 0.002,
            supports_streaming: true,
            supports_functions: true,
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
      attempt = increment_attempts()

      if attempt >= 3 do
        {:ok,
         %{
           id: "flaky-response-#{attempt}",
           provider: :flaky_provider,
           model: "flaky-model",
           choices: [
             %{
               index: 0,
               message: %{role: :assistant, content: "Flaky success after #{attempt} attempts", name: nil, function_call: nil},
               finish_reason: :stop
             }
           ],
           usage: %{prompt_tokens: 10, completion_tokens: 8, total_tokens: 18},
           created_at: DateTime.utc_now(),
           metadata: %{attempt: attempt}
         }}
      else
        {:error, %{reason: :temporary_failure, message: "Attempt #{attempt} failed", retryable: true}}
      end
    end

    @impl true
    def stream(_request, _config) do
      {:error, %{reason: :stream_not_supported, message: "Streaming not implemented", retryable: false}}
    end

    @impl true
    def embed(_input, _config) do
      {:error, %{reason: :embed_not_supported, message: "Embedding not implemented", retryable: false}}
    end

    @impl true
    def list_models(_config), do: {:ok, default_config().models}

    @impl true
    def health_check(_config), do: {:ok, :healthy}
  end

  @sample_request %{
    messages: [%{role: :user, content: "Hello", name: nil, function_call: nil}],
    model: nil,
    temperature: 0.7,
    max_tokens: 100,
    stream: false,
    functions: nil,
    function_call: nil,
    stop: nil,
    metadata: %{}
  }

  setup do
    # Start the flaky provider agent
    case FlakyProvider.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> FlakyProvider.reset()
    end

    # Start the fallback chain GenServer with a unique name for each test
    chain_name = :"#{__MODULE__}_chain_#{System.unique_integer([:positive])}"

    opts = [
      name: chain_name,
      providers: [{SuccessProvider, SuccessProvider.default_config()}],
      max_retries: 3,
      retry_delay_ms: 10,
      circuit_breaker_threshold: 5,
      circuit_breaker_reset_ms: 1000
    ]

    case FallbackChain.start_link(opts) do
      {:ok, pid} ->
        {:ok, %{chain_pid: pid, chain_name: chain_name}}

      {:error, reason} ->
        {:error, "Failed to start FallbackChain: #{inspect(reason)}"}
    end
  end

  describe "complete/3" do
    test "successful completion with first provider", %{chain_name: chain_name} do
      assert {:ok, response} = FallbackChain.complete(chain_name, @sample_request)
      assert response.provider == :success_provider
      assert response.model == "success-model"
      assert length(response.choices) == 1
    end

    test "falls back to second provider when first fails" do
      chain_name = :"#{__MODULE__}_fallback_test_#{System.unique_integer([:positive])}"

      opts = [
        name: chain_name,
        providers: [
          {FailingProvider, FailingProvider.default_config()},
          {SuccessProvider, SuccessProvider.default_config()}
        ],
        max_retries: 1,
        retry_delay_ms: 10
      ]

      {:ok, _pid} = FallbackChain.start_link(opts)

      assert {:ok, response} = FallbackChain.complete(chain_name, @sample_request)
      assert response.provider == :success_provider
    end

    test "returns error when all providers fail" do
      chain_name = :"#{__MODULE__}_all_fail_test_#{System.unique_integer([:positive])}"

      opts = [
        name: chain_name,
        providers: [
          {FailingProvider, FailingProvider.default_config()}
        ],
        max_retries: 1,
        retry_delay_ms: 10
      ]

      {:ok, _pid} = FallbackChain.start_link(opts)

      assert {:error, reason} = FallbackChain.complete(chain_name, @sample_request)
      assert reason.reason == :all_providers_failed
    end
  end

  describe "retry logic" do    test "retries on temporary failures" do
      FlakyProvider.reset()
      chain_name = :"#{__MODULE__}_retry_test_#{System.unique_integer([:positive])}"

      opts = [
        name: chain_name,
        providers: [
          {FlakyProvider, FlakyProvider.default_config()}
        ],
        max_retries: 5,
        retry_delay_ms: 10
      ]

      {:ok, _pid} = FallbackChain.start_link(opts)

      assert {:ok, response} = FallbackChain.complete(chain_name, @sample_request)
      assert response.provider == :flaky_provider
      assert response.metadata.attempt >= 3
    end

    test "stops retrying after max_retries" do
      chain_name = :"#{__MODULE__}_max_retry_test_#{System.unique_integer([:positive])}"

      opts = [
        name: chain_name,
        providers: [
          {FailingProvider, FailingProvider.default_config()}
        ],
        max_retries: 2,
        retry_delay_ms: 10
      ]

      {:ok, _pid} = FallbackChain.start_link(opts)

      assert {:error, _reason} = FallbackChain.complete(chain_name, @sample_request)
    end
  end

  describe "provider management" do
    test "add_provider/3 adds a new provider to the chain", %{chain_name: chain_name} do
      assert :ok = FallbackChain.add_provider(
        chain_name,
        FailingProvider,
        FailingProvider.default_config()
      )

      providers = FallbackChain.list_providers(chain_name)
      assert length(providers) == 2
    end

    test "remove_provider/2 removes a provider from the chain", %{chain_name: chain_name} do
      # First add another provider
      FallbackChain.add_provider(
        chain_name,
        FailingProvider,
        FailingProvider.default_config()
      )

      assert :ok = FallbackChain.remove_provider(chain_name, :failing_provider)

      providers = FallbackChain.list_providers(chain_name)
      assert length(providers) == 1
      assert hd(providers).name == :success_provider
    end

    test "list_providers/1 returns all providers in order", %{chain_name: chain_name} do
      providers = FallbackChain.list_providers(chain_name)
      assert is_list(providers)
      assert length(providers) >= 1
    end
  end

  describe "get_stats/1" do
    test "returns statistics about the chain", %{chain_name: chain_name} do
      # Make a successful request first
      {:ok, _} = FallbackChain.complete(chain_name, @sample_request)

      stats = FallbackChain.get_stats(chain_name)

      assert is_map(stats)
      assert Map.has_key?(stats, :total_requests)
      assert Map.has_key?(stats, :successful_requests)
      assert Map.has_key?(stats, :failed_requests)
      assert Map.has_key?(stats, :fallback_count)
    end

    test "tracks fallback events" do
      chain_name = :"#{__MODULE__}_stats_test_#{System.unique_integer([:positive])}"

      opts = [
        name: chain_name,
        providers: [
          {FailingProvider, FailingProvider.default_config()},
          {SuccessProvider, SuccessProvider.default_config()}
        ],
        max_retries: 1,
        retry_delay_ms: 10
      ]

      {:ok, _pid} = FallbackChain.start_link(opts)

      # Make a request that will fall back
      {:ok, _} = FallbackChain.complete(chain_name, @sample_request)

      stats = FallbackChain.get_stats(chain_name)

      assert stats.total_requests >= 1
      assert stats.successful_requests >= 1
      assert stats.fallback_count >= 1
    end
  end

  describe "circuit breaker integration" do
    test "opens circuit after threshold failures" do
      chain_name = :"#{__MODULE__}_circuit_test_#{System.unique_integer([:positive])}"

      opts = [
        name: chain_name,
        providers: [
          {FailingProvider, FailingProvider.default_config()},
          {SuccessProvider, SuccessProvider.default_config()}
        ],
        max_retries: 1,
        retry_delay_ms: 10,
        circuit_breaker_threshold: 3,
        circuit_breaker_reset_ms: 5000
      ]

      {:ok, _pid} = FallbackChain.start_link(opts)

      # Make multiple requests to trigger circuit breaker
      for _ <- 1..5 do
        FallbackChain.complete(chain_name, @sample_request)
      end

      stats = FallbackChain.get_stats(chain_name)

      # Circuit breaker should have been triggered for failing provider
      # but requests should still succeed via fallback
      assert stats.total_requests == 5
      assert stats.successful_requests == 5
    end
  end

  describe "empty chain" do
    test "returns error when no providers are configured" do
      chain_name = :"#{__MODULE__}_empty_test_#{System.unique_integer([:positive])}"

      opts = [
        name: chain_name,
        providers: [],
        max_retries: 1,
        retry_delay_ms: 10
      ]

      {:ok, _pid} = FallbackChain.start_link(opts)

      assert {:error, reason} = FallbackChain.complete(chain_name, @sample_request)
      assert reason.reason == :no_providers_available
    end
  end

  describe "options validation" do
    test "uses default values when options not provided" do
      chain_name = :"#{__MODULE__}_defaults_test_#{System.unique_integer([:positive])}"

      opts = [
        name: chain_name,
        providers: [{SuccessProvider, SuccessProvider.default_config()}]
      ]

      {:ok, _pid} = FallbackChain.start_link(opts)

      # Should work with default values
      assert {:ok, _response} = FallbackChain.complete(chain_name, @sample_request)
    end
  end
end