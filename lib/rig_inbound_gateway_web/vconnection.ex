defmodule RigInboundGatewayWeb.VConnection do
  @moduledoc """
  The VConnection acts as an abstraction for the actual connections.

  It monitors the processes, sends out heartbeats and subscription refreshes and sends out events to the serverless engine when intialized, connection is lost or connection is re-established.
  """

  alias Rig.EventFilter
  alias Rig.RingBuffer
  alias RigCloudEvents.CloudEvent
  alias RigInboundGateway.Events

  require Logger

  use GenServer

  # TODO: Discuss a reasonable kill delay
  @vconnection_kill_delay 120_000

  # TODO: Discuss a reasonable buffer size
  @buffer_size 100

  def start(pid, subscriptions, heartbeat_interval_ms, subscription_refresh_interval_ms) do
    GenServer.start(__MODULE__,
    %{
      target_pid: pid,
      subscriptions: subscriptions,
      heartbeat_interval_ms: heartbeat_interval_ms,
      subscription_refresh_interval_ms: subscription_refresh_interval_ms,
      kill_timer: nil,
      monitor: nil,
      event_buffer: RingBuffer.new(@buffer_size)
    })
  end

  def start(heartbeat_interval_ms, subscription_refresh_interval_ms) do
    start(nil, [], heartbeat_interval_ms, subscription_refresh_interval_ms)
  end

  @impl true
  def init(state) do
    # TODO: Publish connect event

    Logger.debug(fn -> "New VConnection initialized #{inspect(self())}" end)

    # We register subscriptions:
    send self(), {:set_subscriptions, state.subscriptions}

    # We schedule the initial heartbeat:
    Process.send_after(self(), :heartbeat, state.heartbeat_interval_ms)

    # And the initial subscription refresh:
    Process.send_after(self(), :refresh_subscriptions, state.subscription_refresh_interval_ms)

    if state.target_pid do
      {:ok, create_monitor(state)}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_call(:reconnect, from, state) do
    if state.kill_timer do
      Process.cancel_timer(state.kill_timer)
      Logger.debug(fn -> "Kill-timer #{inspect(state.kill_timer)} stopped" end)
    end

    if state.monitor do
      # Demonitor old connection in case we replace an existing connection
      Process.demonitor(state.monitor)
    end

    # In case an old connection exists, kill it off before replacing it
    send! state.target_pid, :close

    {pid, _} = from

    # Switch target pid
    state = Map.put(state, :target_pid, pid)
    # Register new monitor
    |> create_monitor

    Logger.debug(fn -> "Client #{inspect(pid)} reconnected" end)

    # TODO: Schedule send of all missed events
    # TODO: Publish reconnect event
    {:reply, {:ok, self()}, state}
  end

  @impl true
  def handle_info(:set_subscriptions, state) do
    # Register subscriptions
    send self(), {:set_subscriptions, state.subscriptions}
    {:noreply, state}
  end

  @impl true
  def handle_info(:heartbeat, state) do
    # Send heartbeat to the connection
    send! state.target_pid, {:forward, :heartbeat}

    # And schedule the next one:
    Process.send_after(self(), :heartbeat, state.heartbeat_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info(:refresh_subscriptions, state) do
    EventFilter.refresh_subscriptions(state.subscriptions, [])

    # And schedule the next one:
    Process.send_after(self(), :refresh_subscriptions, state.subscription_refresh_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info(%CloudEvent{} = event, state) do
    Logger.debug(fn -> "event: " <> inspect(event) end)
    send! state.target_pid, {:forward, event}

    # Buffer event so we can send it to the client as soon as there's a reconnect
    state = Map.put(state, :event_buffer, RingBuffer.add(state.event_buffer, event))
    {:noreply, state}
  end

  @impl true
  def handle_info({:set_subscriptions, subscriptions}, state) do
    Logger.debug(fn -> "subscriptions: " <> inspect(subscriptions) end)

    # Trigger immediate refresh:
    EventFilter.refresh_subscriptions(subscriptions, state.subscriptions)

    # Replace current subscriptions:
    state = Map.put(state, :subscriptions, subscriptions)

    send! state.target_pid, {:forward, Events.subscriptions_set(subscriptions)}

    {:noreply, state}
  end

  @impl true
  def handle_info({:set_metadata, metadata}, state) do
    event = Events.metadata_set(metadata)

    send! state.target_pid, {:forward, event}

    {:noreply, state}
  end

  @impl true
  def handle_info({:session_killed, session_id}, state) do
    # Session kill must be handled by the connection
    send! state.target_pid, {:session_killed, session_id}

    # Since the session was killed, there's no need for a VConnection anymore
    send self(), :kill
    {:noreply, state}
  end

  @impl true
  def handle_info(:kill, _state) do
    Logger.debug(fn -> "Virtual Connection went down #{inspect(self())}" end)
    Process.exit(self(), :kill)
  end

  @impl true
  def handle_info(:timeout, state) do
    Logger.debug(fn -> "Connection initialized, timeout starting..." end)

    {:noreply, start_timer(state)}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _}, state) do
    Logger.debug(fn -> "Connection went down #{inspect(pid)}" end)

    # TODO: Publish down event

    {:noreply, start_timer(state)}
  end

  defp create_monitor(state) do
    monitor = Process.monitor(state.target_pid)
    state = Map.put(state, :monitor, monitor)
    state
  end

  defp send!(pid, data)
  defp send!(nil, _data), do: nil
  defp send!(pid, data), do: send pid, data

  defp start_timer(state) do
    timer = Process.send_after(self(), :kill, @vconnection_kill_delay)
    state = Map.put(state, :kill_timer, timer)
    state
  end
end
