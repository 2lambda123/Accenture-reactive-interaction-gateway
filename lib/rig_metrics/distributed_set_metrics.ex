defmodule RigMetrics.DistributedSetMetrics do
  @moduledoc """
  Metrics instrumenter for the Rig Distributed Sets, for example backlist.
  """
  use Prometheus.Metric

  @gauge name: :rig_distributed_set_items_total,
         help: "Total count of items in distributed set.",
         labels: [:name]
  @gauge name: :rig_distributed_set_items_current,
         help: "Current count of items in distributed set.",
         labels: [:name]

  # ---

  @doc "Increases the Prometheus gauges rig_distributed_set_items_total, rig_distributed_set_items_current"
  def add_item(name, increasedBy \\ 1) do
    Gauge.inc([name: :rig_distributed_set_items_total, labels: [name]], increasedBy)
    Gauge.inc([name: :rig_distributed_set_items_current, labels: [name]], increasedBy)
  end

  @doc "Decreases the Prometheus gauge rig_distributed_set_items_current"
  def delete_item(name, decreasedBy \\ 1) do
    Gauge.dec([name: :rig_distributed_set_items_current, labels: [name]], decreasedBy)
  end
end
