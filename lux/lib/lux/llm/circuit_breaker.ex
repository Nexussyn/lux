defmodule Lux.LLM.CircuitBreaker do
  @moduledoc """
  Circuit breaker implementation for provider health management.

  This module provides:

  - Failure tracking per provider
  - Three-state circuit breaker pattern: closed, open, half-open
  - Automatic recovery after cooldown period
  - Configurable failure thresholds and timeouts
  - Telemetry events for state transitions

  ## Circuit States

  - `:closed` - Normal operation, requests are allowed through
  - `:open` - Circuit is tripped, requests are rejected immediately
  - `:half_open` - Testing phase, limited requests allowed to test recovery

  ## Usage

      # Start the circuit breaker (typically done via supervisor)
      {:ok, _pid} = Lux.LLM.CircuitBreaker.start_link()

      # Check if a provider is available
      case Lux.LLM.CircuitBreaker.allow_request?(:openai) do
        true ->
          # Make the request
          case make_request() do
            {:ok, response} ->
              Lux.LLM.CircuitBreaker.record_success(:openai)
              {:ok, response}
            {:error, reason} ->
              Lux.LLM.CircuitBreaker.record_failure(:openai)
              {:error, reason}
          end
        false ->
          {:error, :circuit_open}
      end

  ## Configuration

  The circuit breaker can be configured with the following options:

  - `:failure_threshold` - Number of failures before opening circuit (default: 5)
  - `:reset_timeout` - Milliseconds to wait before half-open (default: 30_000)
  - `:half_open_max_calls` - Max calls allowed in half-open state (default: 1)
  - `:success_threshold` - Successes needed in half-open to close (default: 1)

  """

  use GenServer

  require Logger

  # === Types ===

  @type provider_name :: atom()

  @type circuit_state :: :closed | :open | :half_open

  @type circuit_info :: %{
          state: circuit_state(),
          failure_count: non_neg_integer(),
          success_count: non_neg_integer(),
          last_failure_at: DateTime.t() | nil,
          opened_at: DateTime.t() | nil,
          half_open_calls: non_neg_integer()
        }

  @type config :: %{
          failure_threshold: pos_integer(),
          reset_timeout: pos_integer(),
          half_open_max_calls: pos_integer(),
          success_threshold: pos_integer()
        }

  @type state :: %{
          circuits: %{provider_name() => circuit_info()},
          config: config()
        }

  # === Defaults ===

  @default_failure_threshold 5
  @default_reset_timeout 30_000
  @default_half_open_max_calls 1
  @default_success_threshold 1

  # === Client API ===

  @doc """
  Starts the circuit breaker GenServer.

  ## Options

  - `:name` - The name to register the process under (default: `Lux.LLM.CircuitBreaker`)
  - `:failure_threshold` - Number of failures before opening circuit (default: 5)
  - `:reset_timeout` - Milliseconds to wait before half-open (default: 30_000)
  - `:half_open_max_calls` - Max calls allowed in half-open state (default: 1)
  - `:success_threshold` - Successes needed in half-open to close (default: 1)

  ## Examples

      iex> Lux.LLM.CircuitBreaker.start_link()
      {:ok, #PID<0.123.0>}

      iex> Lux.LLM.CircuitBreaker.start_link(failure_threshold: 10, reset_timeout: 60_000)
      {:ok, #PID<0.124.0>}

  """
  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Checks if a request to the given provider is allowed.

  Returns `true` if the circuit is closed or in half-open state with available calls.
  Returns `false` if the circuit is open.

  ## Examples

      iex> Lux.LLM.CircuitBreaker.allow_request?(:openai)
      true

      iex> Lux.LLM.CircuitBreaker.allow_request?(:failing_provider)
      false

  """
  @spec allow_request?(provider_name(), GenServer.server()) :: boolean()
  def allow_request?(provider, server \\ __MODULE__) do
    GenServer.call(server, {:allow_request?, provider})
  end

  @doc """
  Records a successful request for the given provider.

  In half-open state, this may transition the circuit back to closed.

  ## Examples

      iex> Lux.LLM.CircuitBreaker.record_success(:openai)
      :ok

  """
  @spec record_success(provider_name(), GenServer.server()) :: :ok
  def record_success(provider, server \\ __MODULE__) do
    GenServer.cast(server, {:record_success, provider})
  end

  @doc """
  Records a failed request for the given provider.

  This may transition the circuit to open if the failure threshold is reached.

  ## Examples

      iex> Lux.LLM.CircuitBreaker.record_failure(:openai)
      :ok

  """
  @spec record_failure(provider_name(), GenServer.server()) :: :ok
  def record_failure(provider, server \\ __MODULE__) do
    GenServer.cast(server, {:record_failure, provider})
  end

  @doc """
  Gets the current state of the circuit for a provider.

  ## Examples

      iex> Lux.LLM.CircuitBreaker.get_state(:openai)
      {:ok, :closed}

      iex> Lux.LLM.CircuitBreaker.get_state(:failing_provider)
      {:ok, :open}

  """
  @spec get_state(provider_name(), GenServer.server()) :: {:ok, circuit_state()}
  def get_state(provider, server \\ __MODULE__) do
    GenServer.call(server, {:get_state, provider})
  end

  @doc """
  Gets detailed circuit information for a provider.

  ## Examples

      iex> Lux.LLM.CircuitBreaker.get_info(:openai)
      {:ok, %{state: :closed, failure_count: 0, ...}}

  """
  @spec get_info(provider_name(), GenServer.server()) :: {:ok, circuit_info()}
  def get_info(provider, server \\ __MODULE__) do
    GenServer.call(server, {:get_info, provider})
  end

  @doc """
  Resets the circuit for a provider to closed state.

  This is useful for manual recovery or after administrative actions.

  ## Examples

      iex> Lux.LLM.CircuitBreaker.reset(:openai)
      :ok

  """
  @spec reset(provider_name(), GenServer.server()) :: :ok
  def reset(provider, server \\ __MODULE__) do
    GenServer.cast(server, {:reset, provider})
  end

  @doc """
  Gets information for all tracked circuits.

  ## Examples

      iex> Lux.LLM.CircuitBreaker.get_all_info()
      {:ok, %{openai: %{state: :closed, ...}, anthropic: %{state: :open, ...}}}

  """
  @spec get_all_info(GenServer.server()) :: {:ok, %{provider_name() => circuit_info()}}
  def get_all_info(server \\ __MODULE__) do
    GenServer.call(server, :get_all_info)
  end

  # === Server Callbacks ===

  @impl true
  @spec init(Keyword.t()) :: {:ok, state()}
  def init(opts) do
    config = %{
      failure_threshold: Keyword.get(opts, :failure_threshold, @default_failure_threshold),
      reset_timeout: Keyword.get(opts, :reset_timeout, @default_reset_timeout),
      half_open_max_calls: Keyword.get(opts, :half_open_max_calls, @default_half_open_max_calls),
      success_threshold: Keyword.get(opts, :success_threshold, @default_success_threshold)
    }

    state = %{
      circuits: %{},
      config: config
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:allow_request?, provider}, _from, state) do
    {circuit, state} = get_or_create_circuit(state, provider)
    {circuit, state} = maybe_transition_to_half_open(circuit, state, provider)

    case circuit.state do
      :closed ->
        {:reply, true, state}

      :open ->
        {:reply, false, state}

      :half_open ->
        if circuit.half_open_calls < state.config.half_open_max_calls do
          updated_circuit = %{circuit | half_open_calls: circuit.half_open_calls + 1}
          updated_state = put_in(ctate, [:circuits, provider], updated_circuit)
          {:reply, true, updated_state}
        else
          {:reply, false, state}
        end
    end
  end

  @impl true
  def handle_call({:get_state, provider}, _from, state) do
    {circuit, state} = get_or_create_circuit(state, provider)
    {circuit, state} = maybe_transition_to_half_open(circuit, state, provider)
    {:reply, {:ok, circuit.state}, state}
  end

  @impl true
  def handle_call({:get_info, provider}, _from, state) do
    {circuit, state} = get_or_create_circuit(state, provider)
    {circuit, state} = maybe_transition_to_half_open(circuit, state, provider)
    {:reply, {:ok, circuit}, state}
  end

  @impl true
  def handle_call(:get_all_info, _from, state) do
    {:reply, {:ok, state.circuits}, state}
  end

  @impl true
  def handle_cast({:record_success, provider}, state) do
    {circuit, state} = get_or_create_circuit(state, provider)

    updated_circuit =
      case circuit.state do
        :closed ->
          # Reset failure count on success in closed state
          %{circuit | failure_count: 0, success_count: circuit.success_count + 1}

        :half_open ->
          new_success_count = circuit.success_count + 1

          if new_success_count >= state.config.success_threshold do
            # Transition back to closed
            emit_telemetry(:state_change, provider, :half_open, :closed)
            Logger.info("[CircuitBreaker] Provider #{provider} circuit closed after successful recovery")

            %{
              circuit
              | state: :closed,
                failure_count: 0,
                success_count: 0,
                opened_at: nil,
                half_open_calls: 0
            }
          else
            %{circuit | success_count: new_success_count}
          end

        :open ->
          # Shouldn't happen, but handle gracefully
          circuit
      end

    updated_state = put_in(state, [:circuits, provider], updated_circuit)
    {:noreply, updated_state}
  end

  @impl true
  def handle_cast({:record_failure, provider}, state) do
    {circuit, state} = get_or_create_circuit(state, provider)
    now = DateTime.utc_now()

    updated_circuit =
      case circuit.state do
        :closed ->
          new_failure_count = circuit.failure_count + 1

          if new_failure_count >= state.config.failure_threshold do
            # Trip the circuit
            emit_telemetry(:state_change, provider, :closed, :open)
            Logger.warning(
              "[CircuitBreaker] Provider #{provider} circuit opened after #{new_failure_count} failures"
            )

            %{
              circuit
              | state: :open,
                failure_count: new_failure_count,
                last_failure_at: now,
                opened_at: now
            }
          else
            %{circuit | failure_count: new_failure_count, last_failure_at: now}
          end

        :half_open ->
          # Failure in half-open state, go back to open
          emit_telemetry(:state_change, provider, :half_open, :open)
          Logger.warning("[CircuitBreaker] Provider #{provider} circuit re-opened after half-open failure")

          %{
            circuit
            | state: :open,
              failure_count: circuit.failure_count + 1,
              success_count: 0,
              last_failure_at: now,
              opened_at: now,
              half_open_calls: 0
          }

        :open ->
          # Already open, just update last failure time
          %{circuit | last_failure_at: now}
      end

    updated_state = put_in(state, [:circuits, provider], updated_circuit)
    {:noreply, updated_state}
  end

  @impl true
  def handle_cast({:reset, provider}, state) do
    {circuit, state} = get_or_create_circuit(state, provider)

    if circuit.state != :closed do
      emit_telemetry(:state_change, provider, circuit.state, :closed)
      Logger.info("[CircuitBreaker] Provider #{provider} circuit manually reset to closed")
    end

    reset_circuit = new_circuit()
    updated_state = put_in(state, [:circuits, provider], reset_circuit)
    {:noreply, updated_state}
  end

  # === Private Functions ===

  @spec get_or_create_circuit(state(), provider_name()) :: {circuit_info(), state()}
  defp get_or_create_circuit(state, provider) do
    case Map.get(state.circuits, provider) do
      nil ->
        circuit = new_circuit()
        updated_state = put_in(state, [:circuits, provider], circuit)
        {circuit, updated_state}

      circuit ->
        {circuit, state}
    end
  end

  @spec new_circuit() :: circuit_info()
  defp new_circuit do
    %{
      state: :closed,
      failure_count: 0,
      success_count: 0,
      last_failure_at: nil,
      opened_at: nil,
      half_open_calls: 0
    }
  end

  @spec maybe_transition_to_half_open(circuit_info(), state(), provider_name()) ::
          {circuit_info(), state()}
  defp maybe_transition_to_half_open(circuit, state, provider) do
    case circuit.state do
      :open ->
        if should_transition_to_half_open?(circuit, state.config) do
          emit_telemetry(:state_change, provider, :open, :half_open)
          Logger.info("[CircuitBreaker] Provider #{provider} circuit transitioned to half-open")

          updated_circuit = %{
            circuit
            | state: :half_open,
              success_count: 0,
              half_open_calls: 0
          }

          updated_state = put_in(state, [:circuits, provider], updated_circuit)
          {updated_circuit, updated_state}
        else
          {circuit, state}
        end

      _ ->
        {circuit, state}
    end
  end

  @spec should_transition_to_half_open?(circuit_info(), config()) :: boolean()
  defp should_transition_to_half_open?(circuit, config) do
    case circuit.opened_at do
      nil ->
        false

      opened_at ->
        now = DateTime.utc_now()
        elapsed_ms = DateTime.diff(now, opened_at, :millisecond)
        elapsed_ms >= config.reset_timeout
    end
  end

  @spec emit_telemetry(atom(), provider_name(), circuit_state(), circuit_state()) :: :ok
  defp emit_telemetry(event_type, provider, from_state, to_state) do
    :telemetry.execute(
      [:lux, :llm, :circuit_breaker, event_type],
      %{count: 1},
      %{
        provider: provider,
        from_state: from_state,
        to_state: to_state,
        timestamp: DateTime.utc_now()
      }
    )
  end
end
