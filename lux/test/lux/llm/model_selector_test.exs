defmodule Lux.LLM.ModelSelectorTest do
  @moduledoc """
  Tests for the Lux.LLM.ModelSelector module.

  Verifies model selection logic including:
  - Capability matching
  - Cost optimization
  - Context window filtering
  - Model scoring and ranking
  """

  use ExUnit.Case, async: true

  alias Lux.LLM.ModelSelector

  # Sample model configurations for testing
  @chat_model %{
    id: "gpt-4-turbo",
    name: "GPT-4 Turbo",
    capabilities: [:chat, :completion, :function_calling],
    context_window: 128_000,
    max_output_tokens: 4096,
    cost_per_input_token: 0.01,
    cost_per_output_token: 0.03,
    supports_streaming: true,
    supports_functions: true,
    supports_vision: false
  }

  @cheap_model %{
    id: "gpt-3.5-turbo",
    name: "GPT-3.5 Turbo",
    capabilities: [:chat, :completion],
    context_window: 16_000,
    max_output_tokens: 4096,
    cost_per_input_token: 0.001,
    cost_per_output_token: 0.002,
    supports_streaming: true,
    supports_functions: false,
    supports_vision: false
  }

  @vision_model %{
    id: "gpt-4-vision",
    name: "GPT-4 Vision",
    capabilities: [:chat, :completion, :vision],
    context_window: 128_000,
    max_output_tokens: 4096,
    cost_per_input_token: 0.01,
    cost_per_output_token: 0.03,
    supports_streaming: true,
    supports_functions: false,
    supports_vision: true
  }

  @embedding_model %{
    id: "text-embedding-3-large",
    name: "Text Embedding 3 Large",
    capabilities: [:embedding],
    context_window: 8191,
    max_output_tokens: 0,
    cost_per_input_token: 0.00013,
    cost_per_output_token: 0.0,
    supports_streaming: false,
    supports_functions: false,
    supports_vision: false
  }

  @code_model %{
    id: "code-llama-34b",
    name: "Code Llama 34B",
    capabilities: [:chat, :completion, :code],
    context_window: 16_000,
    max_output_tokens: 2048,
    cost_per_input_token: 0.0005,
    cost_per_output_token: 0.001,
    supports_streaming: true,
    supports_functions: false,
    supports_vision: false
  }

  @small_context_model %{
    id: "small-model",
    name: "Small Model",
    capabilities: [:chat, :completion],
    context_window: 2048,
    max_output_tokens: 512,
    cost_per_input_token: 0.0001,
    cost_per_output_token: 0.0002,
    supports_streaming: false,
    supports_functions: false,
    supports_vision: false
  }

  @all_models [@chat_model, @cheap_model, @vision_model, @embedding_model, @code_model, @small_context_model]

  describe "select/2" do
    test "selects model with required capabilities" do
      criteria = %{required_capabilities: [:vision]}
      assert {:ok, model} = ModelSelector.select(@all_models, criteria)
      assert model.id == "gpt-4-vision"
      assert :vision in model.capabilities
    end

    test "selects model with multiple required capabilities" do
      criteria = %{required_capabilities: [:chat, :function_calling]}
      assert {:ok, model} = ModelSelector.select(@all_models, criteria)
      assert model.id == "gpt-4-turbo"
      assert :chat in model.capabilities
      assert :function_calling in model.capabilities
    end

    test "returns error when no model matches capabilities" do
      criteria = %{required_capabilities: [:image_generation]}
      assert {:error, :no_matching_model} = ModelSelector.select(@all_models, criteria)
    end

    test "returns error when models list is empty" do
      criteria = %{required_capabilities: [:chat]}
      assert {:error, :no_matching_model} = ModelSelector.select([], criteria)
    end

    test "filters by minimum context window" do
      criteria = %{
        required_capabilities: [:chat],
        min_context_window: 64_000
      }
      assert {:ok, model} = ModelSelector.select(@all_models, criteria)
      assert model.context_window >= 64_000
    end

    test "filters out models with insufficient context window" do
      criteria = %{
        required_capabilities: [:chat],
        min_context_window: 256_000
      }
      assert {:error, :no_matching_model} = ModelSelector.select(@all_models, criteria)
    end

    test "filters by maximum cost" do
      criteria = %{
        required_capabilities: [:chat],
        max_cost_per_input_token: 0.002
      }
      assert {:ok, model} = ModelSelector.select(@all_models, criteria)
      assert model.cost_per_input_token <= 0.002
    end

    test "optimizes for cost when strategy is :cheapest" do
      criteria = %{
        required_capabilities: [:chat, :completion],
        strategy: :cheapest
      }
      assert {:ok, model} = ModelSelector.select(@all_models, criteria)
      # Should select the cheapest model with chat and completion
      assert model.id == "small-model"
    end

    test "optimizes for capability when strategy is :most_capable" do
      criteria = %{
        required_capabilities: [:chat],
        strategy: :most_capable
      }
      assert {:ok, model} = ModelSelector.select(@all_models, criteria)
      # Should select the model with most capabilities
      assert model.id == "gpt-4-turbo"
    end

    test "optimizes for context window when strategy is :largest_context" do
      criteria = %{
        required_capabilities: [:chat],
        strategy: :largest_context
      }
      assert {:ok, model} = ModelSelector.select(@all_models, criteria)
      # Should select model with largest context window
      assert model.context_window == 128_000
    end

    test "requires streaming support when specified" do
      criteria = %{
        required_capabilities: [:chat],
        requires_streaming: true
      }
      assert {:ok, model} = ModelSelector.select(@all_models, criteria)
      assert model.supports_streaming == true
    end

    test "uses default strategy when none specified" do
      criteria = %{required_capabilities: [:chat]}
      assert {:ok, _model} = ModelSelector.select(@all_models, criteria)
    end
  end

  describe "select_all/2" do
    test "returns all matching models sorted by score" do
      criteria = %{required_capabilities: [:chat]}
      assert {:ok, models} = ModelSelector.select_all(@all_models, criteria)
      assert length(models) >= 2
      assert Enum.all?(models, fn m -> :chat in m.capabilities end)
    end

    test "returns empty list when no models match" do
      criteria = %{required_capabilities: [:image_generation]}
      assert {:ok, []} = ModelSelector.select_all(@all_models, criteria)
    end

    test "sorts by cost when strategy is :cheapest" do
      criteria = %{
        required_capabilities: [:chat],
        strategy: :cheapest
      }
      assert {:ok, models} = ModelSelector.select_all(@all_models, criteria)
      costs = Enum.map(models, fn m -> m.cost_per_input_token + m.cost_per_output_token end)
      assert costs == Enum.sort(costs)
    end
  end

  describe "matches_capabilities?/2" do
    test "returns true when model has all required capabilities" do
      assert ModelSelector.matches_capabilities?(@chat_model, [:chat, :completion])
    end

    test "returns false when model is missing capabilities" do
      refute ModelSelector.matches_capabilities?(@cheap_model, [:function_calling])
    end

    test "returns true when no capabilities required" do
      assert ModelSelector.matches_capabilities?(@cheap_model, [])
    end
  end

  describe "calculate_cost/3" do
    test "calculates cost based on tokens" do
      input_tokens = 1000
      output_tokens = 500

      expected_cost = (@chat_model.cost_per_input_token * input_tokens) +
                      (@chat_model.cost_per_output_token * output_tokens)

      assert ModelSelector.calculate_cost(@chat_model, input_tokens, output_tokens) == expected_cost
    end

    test "returns zero for zero tokens" do
      assert ModelSelector.calculate_cost(@chat_model, 0, 0) == 0.0
    end
  end

  describe "score_model/2" do
    test "scores model based on criteria" do
      criteria = %{
        required_capabilities: [:chat],
        strategy: :cheapest
      }
      score = ModelSelector.score_model(@cheap_model, criteria)
      assert is_number(score)
    end

    test "cheaper models score higher with :cheapest strategy" do
      criteria = %{
        required_capabilities: [:chat],
        strategy: :cheapest
      }
      cheap_score = ModelSelector.score_model(@cheap_model, criteria)
      expensive_score = ModelSelector.score_model(@chat_model, criteria)
      assert cheap_score > expensive_score
    end

    test "more capable models score higher with :most_capable strategy" do
      criteria = %{
        required_capabilities: [:chat],
        strategy: :most_capable
      }
      capable_score = ModelSelector.score_model(@chat_model, criteria)
      less_capable_score = ModelSelector.score_model(@cheap_model, criteria)
      assert capable_score > less_capable_score
    end
  end

  describe "filter_models/2" do
    test "filters by capabilities" do
      criteria = %{required_capabilities: [:embedding]}
      filtered = ModelSelector.filter_models(@all_models, criteria)
      assert length(filtered) == 1
      assert hd(filtered).id == "text-embedding-3-large"
    end

    test "filters by minimum context window" do
      criteria = %{
        required_capabilities: [],
        min_context_window: 50_000
      }
      filtered = ModelSelector.filter_models(@all_models, criteria)
      assert Enum.all?(filtered, fn m -> m.context_window >= 50_000 end)
    end

    test "filters by streaming support" do
      criteria = %{
        required_capabilities: [],
        requires_streaming: true
      }
      filtered = ModelSelector.filter_models(@all_models, criteria)
      assert Enum.all?(filtered, fn m -> m.supports_streaming end)
    end

    test "filters by function support" do
      criteria = %{
        required_capabilities: [],
        requires_functions: true
      }
      filtered = ModelSelector.filter_models(@all_models, criteria)
      assert Enum.all?(filtered, fn m -> m.supports_functions end)
    end

    test "applies multiple filters" do
      criteria = %{
        required_capabilities: [:chat],
        min_context_window: 10_000,
        requires_streaming: true,
        max_cost_per_input_token: 0.005
      }
      filtered = ModelSelector.filter_models(@all_models, criteria)

      assert Enum.all?(filtered, fn m ->
        :chat in m.capabilities and
        m.context_window >= 10_000 and
        m.supports_streaming and
        m.cost_per_input_token <= 0.005
      end)
    end
  end

  describe "edge cases" do
    test "handles empty criteria" do
      assert {:ok, _model} = ModelSelector.select(@all_models, %{})
    end

    test "handles criteria with only strategy" do
      criteria = %{strategy: :cheapest}
      assert {:ok, _model} = ModelSelector.select(@all_models, criteria)
    end

    test "handles single model in list" do
      criteria = %{required_capabilities: [:chat]}
      assert {:ok, model} = ModelSelector.select([@chat_model], criteria)
      assert model.id == "gpt-4-turbo"
    end

    test "handles models with zero cost" do
      free_model = %{
        id: "free-model",
        name: "Free Model",
        capabilities: [:chat],
        context_window: 4096,
        max_output_tokens: 1024,
        cost_per_input_token: 0.0,
        cost_per_output_token: 0.0,
        supports_streaming: false,
        supports_functions: false,
        supports_vision: false
      }

      criteria = %{required_capabilities: [:chat], strategy: :cheapest}
      assert {:ok, model} = ModelSelector.select([free_model | @all_models], criteria)
      assert model.id == "free-model"
    end
  end
end