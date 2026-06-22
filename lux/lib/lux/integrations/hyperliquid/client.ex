# Fix for Issue #82: Hyperliquid Integration and Perpetual Trading $900

defmodule Lux.Integrations.Hyperliquid.Types do
  @moduledoc """
  Type definitions for Hyperliquid integration.
  
  Provides structured types for orders, positions, margins, and risk parameters.
  """

  @type asset :: String.t()
  @type side :: :long | :short
  @type order_type :: :limit | :market | :stop_limit | :stop_market | :take_profit | :take_profit_limit
  @type order_status :: :pending | :open | :filled | :partially_filled | :cancelled | :rejected
  @type time_in_force :: :gtc | :ioc | :fok | :post_only

  defmodule Order do
    @moduledoc "Represents a trading order"
    
    @enforce_keys [:asset, :side, :size, :order_type]
    defstruct [
      :id,
      :asset,
      :side,
      :size,
      :price,
      :order_type,
      :reduce_only,
      :time_in_force,
      :trigger_price,
      :client_order_id,
      :status,
      :filled_size,
      :average_fill_price,
      :created_at,
      :updated_at
    ]

    @type t :: %__MODULE__{
      id: String.t() | nil,
      asset: String.t(),
      side: :long | :short,
      size: Decimal.t(),
      price: Decimal.t() | nil,
      order_type: atom(),
      reduce_only: boolean() | nil,
      time_in_force: atom() | nil,
      trigger_price: Decimal.t() | nil,
      client_order_id: String.t() | nil,
      status: atom() | nil,
      filled_size: Decimal.t() | nil,
      average_fill_price: Decimal.t() | nil,
      created_at: DateTime.t() | nil,
      updated_at: DateTime.t() | nil
    }
  end

  defmodule Position do
    @moduledoc "Represents an open position"
    
    @enforce_keys [:asset, :side, :size, :entry_price]
    defstruct [
      :asset,
      :side,
      :size,
      :entry_price,
      :mark_price,
      :liquidation_price,
      :unrealized_pnl,
      :realized_pnl,
      :leverage,
      :margin,
      :margin_ratio,
      :notional_value,
      :funding_payment,
      :last_funding_rate,
      :created_at,
      :updated_at
    ]

    @type t :: %__MODULE__{
      asset: String.t(),
      side: :long | :short,
      size: Decimal.t(),
      entry_price: Decimal.t(),
      mark_price: Decimal.t() | nil,
      liquidation_price: Decimal.t() | nil,
      unrealized_pnl: Decimal.t() | nil,
      realized_pnl: Decimal.t() | nil,
      leverage: Decimal.t() | nil,
      margin: Decimal.t() | nil,
      margin_ratio: Decimal.t() | nil,
      notional_value: Decimal.t() | nil,
      funding_payment: Decimal.t() | nil,
      last_funding_rate: Decimal.t() | nil,
      created_at: DateTime.t() | nil,
      updated_at: DateTime.t() | nil
    }
  end

  defmodule MarginInfo do
    @moduledoc "Represents account margin information"
    
    defstruct [
      :total_margin,
      :available_margin,
      :used_margin,
      :maintenance_margin,
      :initial_margin,
      :margin_ratio,
      :leverage,
      :account_value,
      :unrealized_pnl,
      :realized_pnl
    ]

    @type t :: %__MODULE__{
      total_margin: Decimal.t() | nil,
      available_margin: Decimal.t() | nil,
      used_margin: Decimal.t() | nil,
      maintenance_margin: Decimal.t() | nil,
      initial_margin: Decimal.t() | nil,
      margin_ratio: Decimal.t() | nil,
      leverage: Decimal.t() | nil,
      account_value: Decimal.t() | nil,
      unrealized_pnl: Decimal.t() | nil,
      realized_pnl: Decimal.t() | nil
    }
  end

  defmodule RiskParameters do
    @moduledoc "Risk management parameters"
    
    defstruct [
      max_position_size: Decimal.new("100000"),
      max_leverage: Decimal.new("50"),
      max_drawdown_percent: Decimal.new("10"),
      max_daily_loss: Decimal.new("5000"),
      liquidation_threshold: Decimal.new("80"),
      margin_call_threshold: Decimal.new("70"),
      stop_loss_percent: Decimal.new("5"),
      take_profit_percent: Decimal.new("10"),
      max_open_orders: 100,
      max_positions: 20
    ]

    @type t :: %__MODULE__{
      max_position_size: Decimal.t(),
      max_leverage: Decimal.t(),
      max_drawdown_percent: Decimal.t(),
      max_daily_loss: Decimal.t(),
      liquidation_threshold: Decimal.t(),
      margin_call_threshold: Decimal.t(),
      stop_loss_percent: Decimal.t(),
      take_profit_percent: Decimal.t(),
      max_open_orders: non_neg_integer(),
      max_positions: non_neg_integer()
    }
  end

  defmodule PnLRecord do
    @moduledoc "Profit and Loss record"
    
    defstruct [
      :asset,
      :realized_pnl,
      :unrealized_pnl,
      :total_pnl,
      :fees_paid,
      :funding_received,
      :period_start,
      :period_end,
      :trades_count,
      :win_rate
    ]

    @type t :: %__MODULE__{
      asset: String.t() | nil,
      realized_pnl: Decimal.t() | nil,
      unrealized_pnl: Decimal.t() | nil,
      total_pnl: Decimal.t() | nil,
      fees_paid: Decimal.t() | nil,
      funding_received: Decimal.t() | nil,
      period_start: DateTime.t() | nil,
      period_end: DateTime.t() | nil,
      trades_count: non_neg_integer() | nil,
      win_rate: Decimal.t() | nil
    }
  end

  defmodule LiquidationRisk do
    @moduledoc "Liquidation risk assessment"
    
    defstruct [
      :asset,
      :current_price,
      :liquidation_price,
      :distance_to_liquidation,
      :distance_percent,
      :risk_level,
      :recommended_action,
      :margin_to_add
    ]

    @type t :: %__MODULE__{
      asset: String.t() | nil,
      current_price: Decimal.t() | nil,
      liquidation_price: Decimal.t() | nil,
      distance_to_liquidation: Decimal.t() | nil,
      distance_percent: Decimal.t() | nil,
      risk_level: :low | :medium | :high | :critical | nil,
      recommended_action: String.t() | nil,
      margin_to_add: Decimal.t() | nil
    }
  end
end