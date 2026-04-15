# Elixir runtime for railcar-generated apps.
# Hand-written Elixir (not transpiled from Crystal).
#
# Provides an ActiveRecord-like API using Exqlite for SQLite:
#   Blog.Article.find(1)      → %Blog.Article{id: 1, title: "..."}
#   Blog.Article.all()        → [%Blog.Article{}, ...]
#   Blog.Article.create(attrs) → {:ok, %Blog.Article{}} | {:error, errors}
#   Blog.Article.save(record) → {:ok, record} | {:error, errors}

defmodule Railcar.Record do
  @moduledoc """
  Base module for railcar model definitions.
  `use Railcar.Record` provides CRUD, validations, and associations.
  """

  defmacro __using__(opts) do
    table = Keyword.fetch!(opts, :table)
    columns = Keyword.get(opts, :columns, [])

    quote do
      @table unquote(table)
      @columns unquote(columns)

      defstruct [:id | @columns] ++ [_persisted: false, errors: []]

      # --- Query interface ---

      def table_name, do: @table
      def columns, do: @columns

      def find(id) do
        db = Railcar.Repo.db()
        {:ok, stmt} = Exqlite.Sqlite3.prepare(db, "SELECT * FROM #{@table} WHERE id = ?")
        Exqlite.Sqlite3.bind(stmt, [id])

        case Exqlite.Sqlite3.step(db, stmt) do
          {:row, row} ->
            {:ok, names} = Exqlite.Sqlite3.columns(db, stmt)
            Exqlite.Sqlite3.release(db, stmt)
            from_row(Enum.zip(names, row) |> Map.new())

          :done ->
            Exqlite.Sqlite3.release(db, stmt)
            raise "#{__MODULE__} not found: #{id}"
        end
      end

      def all(order_by \\ "id") do
        db = Railcar.Repo.db()
        {:ok, stmt} = Exqlite.Sqlite3.prepare(db, "SELECT * FROM #{@table} ORDER BY #{order_by}")
        rows = fetch_all(db, stmt)
        Exqlite.Sqlite3.release(db, stmt)
        Enum.map(rows, &from_row/1)
      end

      def where(conditions) do
        db = Railcar.Repo.db()
        {clauses, values} =
          Enum.reduce(conditions, {[], []}, fn {k, v}, {cs, vs} ->
            {cs ++ ["#{k} = ?"], vs ++ [v]}
          end)

        sql = "SELECT * FROM #{@table} WHERE #{Enum.join(clauses, " AND ")}"
        {:ok, stmt} = Exqlite.Sqlite3.prepare(db, sql)
        Exqlite.Sqlite3.bind(stmt, values)
        rows = fetch_all(db, stmt)
        Exqlite.Sqlite3.release(db, stmt)
        Enum.map(rows, &from_row/1)
      end

      def count do
        db = Railcar.Repo.db()
        {:ok, stmt} = Exqlite.Sqlite3.prepare(db, "SELECT COUNT(*) FROM #{@table}")

        case Exqlite.Sqlite3.step(db, stmt) do
          {:row, [n]} ->
            Exqlite.Sqlite3.release(db, stmt)
            n

          _ ->
            Exqlite.Sqlite3.release(db, stmt)
            0
        end
      end

      def last do
        case all() do
          [] -> nil
          records -> List.last(records)
        end
      end

      def create(attrs \\ %{}) do
        record = struct(__MODULE__, attrs)
        save(record)
      end

      # --- Persistence ---

      def save(%{_persisted: true} = record) do
        case run_validations(record) do
          [] -> do_update(record)
          errors -> {:error, %{record | errors: errors}}
        end
      end

      def save(record) do
        case run_validations(record) do
          [] -> do_insert(record)
          errors -> {:error, %{record | errors: errors}}
        end
      end

      def update(record, attrs) do
        updated = struct(record, attrs)
        save(%{updated | _persisted: true})
      end

      def delete(record) do
        db = Railcar.Repo.db()
        {:ok, stmt} = Exqlite.Sqlite3.prepare(db, "DELETE FROM #{@table} WHERE id = ?")
        Exqlite.Sqlite3.bind(stmt, [record.id])
        Exqlite.Sqlite3.step(db, stmt)
        Exqlite.Sqlite3.release(db, stmt)
        :ok
      end

      def reload(record) do
        find(record.id)
      end

      # --- Validations (override in model) ---

      def run_validations(_record), do: []

      defoverridable run_validations: 1, delete: 1

      # --- Internal ---

      defp do_insert(record) do
        db = Railcar.Repo.db()
        now = NaiveDateTime.utc_now() |> NaiveDateTime.to_string()
        cols = @columns -- [:created_at, :updated_at]
        record = if :created_at in @columns, do: %{record | created_at: now}, else: record
        record = if :updated_at in @columns, do: %{record | updated_at: now}, else: record

        all_cols = cols ++ (if :created_at in @columns, do: [:created_at, :updated_at], else: [])
        values = Enum.map(all_cols, &Map.get(record, &1))
        placeholders = Enum.map(all_cols, fn _ -> "?" end) |> Enum.join(", ")
        col_names = Enum.map(all_cols, &to_string/1) |> Enum.join(", ")

        {:ok, stmt} = Exqlite.Sqlite3.prepare(db,
          "INSERT INTO #{@table} (#{col_names}) VALUES (#{placeholders})")
        Exqlite.Sqlite3.bind(stmt, values)
        Exqlite.Sqlite3.step(db, stmt)
        Exqlite.Sqlite3.release(db, stmt)

        {:ok, id} = Exqlite.Sqlite3.last_insert_rowid(db)
        {:ok, %{record | id: id, _persisted: true}}
      end

      defp do_update(record) do
        db = Railcar.Repo.db()
        now = NaiveDateTime.utc_now() |> NaiveDateTime.to_string()
        record = if :updated_at in @columns, do: %{record | updated_at: now}, else: record

        cols = @columns -- [:created_at]
        sets = Enum.map(cols, fn c -> "#{c} = ?" end) |> Enum.join(", ")
        values = Enum.map(cols, &Map.get(record, &1)) ++ [record.id]

        {:ok, stmt} = Exqlite.Sqlite3.prepare(db,
          "UPDATE #{@table} SET #{sets} WHERE id = ?")
        Exqlite.Sqlite3.bind(stmt, values)
        Exqlite.Sqlite3.step(db, stmt)
        Exqlite.Sqlite3.release(db, stmt)

        {:ok, record}
      end

      defp fetch_all(db, stmt) do
        {:ok, names} = Exqlite.Sqlite3.columns(db, stmt)
        fetch_all_rows(db, stmt, names, [])
      end

      defp fetch_all_rows(db, stmt, names, acc) do
        case Exqlite.Sqlite3.step(db, stmt) do
          {:row, row} ->
            map = Enum.zip(names, row) |> Map.new()
            fetch_all_rows(db, stmt, names, acc ++ [map])

          :done ->
            acc
        end
      end

      defp from_row(map) do
        attrs =
          Enum.reduce([:id | @columns], %{}, fn col, acc ->
            key = to_string(col)
            Map.put(acc, col, Map.get(map, key))
          end)

        struct(__MODULE__, Map.put(attrs, :_persisted, true))
      end
    end
  end
end

defmodule Railcar.Repo do
  @moduledoc "Simple SQLite database connection via process dictionary."

  def start(db_path) do
    {:ok, db} = Exqlite.Sqlite3.open(db_path)
    Exqlite.Sqlite3.execute(db, "PRAGMA foreign_keys = ON")
    Process.put(:railcar_db, db)
    db
  end

  def db do
    Process.get(:railcar_db) || raise "Database not started. Call Railcar.Repo.start/1 first."
  end

  def execute(sql) do
    Exqlite.Sqlite3.execute(db(), sql)
  end
end

defmodule Railcar.CableServer do
  @moduledoc "ActionCable WebSocket server for Turbo Streams broadcasting."
  use GenServer

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(_) do
    {:ok, %{channels: %{}}}
  end

  def subscribe(channel, ws_pid, identifier) do
    GenServer.cast(__MODULE__, {:subscribe, channel, ws_pid, identifier})
  end

  def unsubscribe_all(ws_pid) do
    GenServer.cast(__MODULE__, {:unsubscribe_all, ws_pid})
  end

  def broadcast(channel, html) do
    GenServer.cast(__MODULE__, {:broadcast, channel, html})
  end

  def handle_cast({:subscribe, channel, ws_pid, identifier}, state) do
    subs = Map.get(state.channels, channel, MapSet.new())
    subs = MapSet.put(subs, {ws_pid, identifier})
    {:noreply, %{state | channels: Map.put(state.channels, channel, subs)}}
  end

  def handle_cast({:unsubscribe_all, ws_pid}, state) do
    channels = Enum.reduce(state.channels, %{}, fn {channel, subs}, acc ->
      filtered = MapSet.reject(subs, fn {pid, _} -> pid == ws_pid end)
      if MapSet.size(filtered) > 0, do: Map.put(acc, channel, filtered), else: acc
    end)
    {:noreply, %{state | channels: channels}}
  end

  def handle_cast({:broadcast, channel, html}, state) do
    subs = Map.get(state.channels, channel, MapSet.new())
    for {ws_pid, identifier} <- subs do
      msg = Jason.encode!(%{type: "message", identifier: identifier, message: html})
      send(ws_pid, {:send_text, msg})
    end
    {:noreply, state}
  end
end

defmodule Railcar.CableHandler do
  @moduledoc "WebSocket handler for Action Cable protocol."
  @behaviour WebSock

  @impl true
  def init(_opts) do
    send(self(), :welcome)
    send(self(), :start_ping)
    {:ok, %{}}
  end

  @impl true
  def handle_in({text, [opcode: :text]}, state) do
    case Jason.decode(text) do
      {:ok, %{"command" => "subscribe", "identifier" => identifier}} ->
        id_data = Jason.decode!(identifier)
        signed = Map.get(id_data, "signed_stream_name", "")
        channel = signed |> String.split("--") |> List.first() |> Base.decode64!() |> Jason.decode!()
        Railcar.CableServer.subscribe(channel, self(), identifier)
        confirm = Jason.encode!(%{type: "confirm_subscription", identifier: identifier})
        {:push, {:text, confirm}, state}

      _ ->
        {:ok, state}
    end
  end

  @impl true
  def handle_info(:welcome, state) do
    {:push, {:text, Jason.encode!(%{type: "welcome"})}, state}
  end

  def handle_info(:start_ping, state) do
    Process.send_after(self(), :ping, 3000)
    {:ok, state}
  end

  def handle_info(:ping, state) do
    Process.send_after(self(), :ping, 3000)
    {:push, {:text, Jason.encode!(%{type: "ping", message: System.system_time(:second)})}, state}
  end

  def handle_info({:send_text, msg}, state) do
    {:push, {:text, msg}, state}
  end

  @impl true
  def terminate(_reason, _state) do
    Railcar.CableServer.unsubscribe_all(self())
    :ok
  end
end

defmodule Railcar.Broadcast do
  @moduledoc "Turbo Streams broadcast helpers for models."

  def turbo_stream_html(action, target, content \\ "") do
    if content != "" do
      ~s(<turbo-stream action="#{action}" target="#{target}"><template>#{content}</template></turbo-stream>)
    else
      ~s(<turbo-stream action="#{action}" target="#{target}"></turbo-stream>)
    end
  end

  def broadcast_replace_to(record, channel, opts \\ []) do
    target = opts[:target] || dom_id(record)
    html = render_partial(record)
    stream = turbo_stream_html("replace", target, html)
    Railcar.CableServer.broadcast(channel, stream)
  end

  def broadcast_prepend_to(record, channel, opts \\ []) do
    target = opts[:target] || table_name(record)
    html = render_partial(record)
    stream = turbo_stream_html("prepend", target, html)
    Railcar.CableServer.broadcast(channel, stream)
  end

  def broadcast_remove_to(record, channel, opts \\ []) do
    target = opts[:target] || dom_id(record)
    stream = turbo_stream_html("remove", target)
    Railcar.CableServer.broadcast(channel, stream)
  end

  defp dom_id(record) do
    name = record.__struct__ |> Module.split() |> List.last() |> String.downcase()
    "#{name}_#{record.id}"
  end

  defp table_name(record) do
    record.__struct__.table_name()
  end

  defp render_partial(record) do
    module = record.__struct__
    case Process.get({:render_partial, module}) do
      nil -> "<div>#{inspect(record)}</div>"
      func -> func.(record)
    end
  end

  def register_partial(module, func) do
    Process.put({:render_partial, module}, func)
  end
end

defmodule Railcar.Validation do
  @moduledoc "Validation helpers for railcar models."

  def validate_presence(record, field) do
    value = Map.get(record, field)

    if is_nil(value) || (is_binary(value) && String.trim(value) == "") do
      [{field, "can't be blank"}]
    else
      []
    end
  end

  def validate_length(record, field, opts) do
    value = Map.get(record, field)
    min = Keyword.get(opts, :minimum)

    cond do
      is_nil(value) -> []
      min && is_binary(value) && String.length(value) < min ->
        [{field, "is too short (minimum is #{min} characters)"}]
      true -> []
    end
  end

  def validate_belongs_to(record, field, model_module) do
    fk = :"#{field}_id"
    value = Map.get(record, fk)

    if is_nil(value) do
      [{field, "must exist"}]
    else
      try do
        model_module.find(value)
        []
      rescue
        _ -> [{field, "must exist"}]
      end
    end
  end
end
