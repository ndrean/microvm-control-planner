defmodule FcExCp.DesiredStateStore do
  @moduledoc """
  Persistent storage for desired VM state.

  Loads initial configuration from config/desired_vms.exs on startup.
  Provides CRUD operations with SQLite persistence.
  """
  use GenServer

  require Logger

  @default_config_path "config/desired_vms.exs"

  def start_link([db_path]), do: GenServer.start_link(__MODULE__, db_path, name: __MODULE__)

  def start_link(db_path) when is_binary(db_path),
    do: GenServer.start_link(__MODULE__, db_path, name: __MODULE__)

  def put(vm_id, tenant, spec_map),
    do: GenServer.call(__MODULE__, {:put, vm_id, tenant, spec_map})

  def delete(vm_id), do: GenServer.call(__MODULE__, {:delete, vm_id})
  def list(), do: GenServer.call(__MODULE__, :list)
  def get(vm_id), do: GenServer.call(__MODULE__, {:get, vm_id})

  def delete_all, do: GenServer.cast(__MODULE__, :delete_all)

  @impl true
  def init(db_path) do
    {:ok, conn} = Exqlite.Sqlite3.open(db_path)
    :ok = Exqlite.Sqlite3.execute(conn, "PRAGMA journal_mode=WAL;")

    :ok =
      Exqlite.Sqlite3.execute(conn, """
      CREATE TABLE IF NOT EXISTS desired_vms (
        vm_id TEXT PRIMARY KEY,
        tenant TEXT,
        spec_json TEXT NOT NULL,
        inserted_at INTEGER NOT NULL
      );
      """)

    {:ok, %{conn: conn}, {:continue, :put_desired_state}}
  end

  @impl true
  def handle_continue(:put_desired_state, st) do
    # Load desired state from config file
    desired_state = load_config_file()
    send(self(), {:put_desired_state, desired_state})
    {:noreply, st}
  end

  @impl true
  def handle_info({:put_desired_state, desired_states}, st) do
    now = System.os_time(:second)

    sql = """
    INSERT INTO desired_vms(vm_id, tenant, spec_json, inserted_at)
    VALUES (?1, ?2, ?3, ?4)
    ON CONFLICT(vm_id) DO UPDATE SET
      tenant=excluded.tenant,
      spec_json=excluded.spec_json,
      inserted_at=excluded.inserted_at;
    """

    for {vm_id, tenant, raw_spec} <- desired_states do
      spec_json = Jason.encode!(raw_spec)
      {:ok, stmt} = Exqlite.Sqlite3.prepare(st.conn, sql)
      :ok = Exqlite.Sqlite3.bind(stmt, [vm_id, tenant, spec_json, now])
      :done = Exqlite.Sqlite3.step(st.conn, stmt)
      :ok = Exqlite.Sqlite3.release(st.conn, stmt)
    end

    {:noreply, st}
  end

  @impl true
  def handle_call({:put, vm_id, tenant, spec_map}, _from, st) do
    now = System.os_time(:second)
    spec_json = Jason.encode!(spec_map)

    sql = """
    INSERT INTO desired_vms(vm_id, tenant, spec_json, inserted_at)
    VALUES (?1, ?2, ?3, ?4)
    ON CONFLICT(vm_id) DO UPDATE SET
      tenant=excluded.tenant,
      spec_json=excluded.spec_json,
      inserted_at=excluded.inserted_at;
    """

    {:ok, stmt} = Exqlite.Sqlite3.prepare(st.conn, sql)
    :ok = Exqlite.Sqlite3.bind(stmt, [vm_id, tenant, spec_json, now])
    :done = Exqlite.Sqlite3.step(st.conn, stmt)
    :ok = Exqlite.Sqlite3.release(st.conn, stmt)

    {:reply, :ok, st}
  end

  @impl true
  def handle_call({:delete, vm_id}, _from, st) do
    sql = "DELETE FROM desired_vms WHERE vm_id=?1"
    {:ok, stmt} = Exqlite.Sqlite3.prepare(st.conn, sql)
    :ok = Exqlite.Sqlite3.bind(stmt, [vm_id])
    :done = Exqlite.Sqlite3.step(st.conn, stmt)
    :ok = Exqlite.Sqlite3.release(st.conn, stmt)
    {:reply, :ok, st}
  end

  @impl true
  def handle_call({:get, vm_id}, _from, st) do
    sql = "SELECT vm_id, tenant, spec_json FROM desired_vms WHERE vm_id=?1"
    {:ok, stmt} = Exqlite.Sqlite3.prepare(st.conn, sql)
    :ok = Exqlite.Sqlite3.bind(stmt, [vm_id])

    reply =
      case Exqlite.Sqlite3.step(st.conn, stmt) do
        {:row, [id, tenant, spec_json]} ->
          {:ok, %{vm_id: id, tenant: tenant, spec: Jason.decode!(spec_json)}}

        :done ->
          :error
      end

    :ok = Exqlite.Sqlite3.release(st.conn, stmt)
    {:reply, reply, st}
  end

  @impl true
  def handle_call(:list, _from, st) do
    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(st.conn, "SELECT vm_id, tenant, spec_json FROM desired_vms")

    rows = read_all_rows(st.conn, stmt, [])
    :ok = Exqlite.Sqlite3.release(st.conn, stmt)

    desired =
      for [vm_id, tenant, spec_json] <- rows, into: %{} do
        {vm_id, %{tenant: tenant, spec: Jason.decode!(spec_json)}}
      end

    {:reply, desired, st}
  end

  @impl true
  def handle_cast(:delete_all, st) do
    Exqlite.Sqlite3.execute(st.conn, "DELETE from desired_vms")
    {:noreply, st}
  end

  defp read_all_rows(conn, stmt, acc) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, row} -> read_all_rows(conn, stmt, [row | acc])
      :done -> Enum.reverse(acc)
    end
  end

  defp load_config_file do
    config_path =
      Application.get_env(:fc_ex_cp, :desired_vms_config, @default_config_path)

    case File.read(config_path) do
      {:ok, content} ->
        case Code.eval_string(content) do
          {desired_vms, _binding} when is_list(desired_vms) ->
            Logger.info("Loaded #{length(desired_vms)} VMs from #{config_path}")
            desired_vms

          _ ->
            Logger.warning("Invalid config format in #{config_path}, using empty list")
            []
        end

      {:error, :enoent} ->
        Logger.info("No config file found at #{config_path}, starting with empty state")
        []

      {:error, reason} ->
        Logger.error("Failed to read config file #{config_path}: #{inspect(reason)}")
        []
    end
  end
end
