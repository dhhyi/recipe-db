defmodule Recipes.StorageVersion do
  @moduledoc false

  @expected_version Recipes.StorageVersionGenerated.value()

  def check!(database, mode) do
    root = Path.dirname(database)
    marker = Path.join(root, "storage-version")
    marker_version = marker_version!(marker)
    entries = data_entries!(root, marker)

    validate_storage!(marker_version, entries, marker, mode, database)
  end

  def publish!(database) do
    marker = Path.join(Path.dirname(database), "storage-version")
    temporary = marker <> ".pending-#{System.unique_integer([:positive])}"

    try do
      write_temporary_marker!(temporary, marker)
      publish_marker!(temporary, marker)
    rescue
      error in RuntimeError ->
        reraise error, __STACKTRACE__

      error ->
        fail!(marker, "cannot publish marker: #{Exception.message(error)}")
    after
      File.rm(temporary)
    end
  end

  defp marker_version!(marker) do
    case File.lstat(marker) do
      {:error, :enoent} -> nil
      {:ok, %{type: :regular}} -> read_marker!(marker)
      {:ok, _} -> fail!(marker, "unsafe marker file type")
      {:error, reason} -> fail!(marker, "cannot inspect marker: #{:file.format_error(reason)}")
    end
  end

  defp data_entries!(root, marker) do
    case File.ls(root) do
      {:ok, names} -> Enum.reject(names, &(&1 == "storage-version"))
      {:error, :enoent} -> []
      {:error, reason} -> fail!(marker, "cannot inspect data root: #{:file.format_error(reason)}")
    end
  end

  defp validate_storage!(nil, [], marker, mode, _database) do
    require_initialization_mode!(mode, marker)
    :fresh
  end

  defp validate_storage!(nil, _entries, marker, _mode, _database),
    do: fail!(marker, "marker missing; existing data found")

  defp validate_storage!(version, _entries, marker, _mode, _database)
       when version != @expected_version,
       do: fail!(marker, "actual #{version}")

  defp validate_storage!(_version, [], marker, mode, _database) do
    require_initialization_mode!(mode, marker)
    :initialize
  end

  defp validate_storage!(_version, _entries, marker, _mode, database),
    do: validate_database!(database, marker)

  defp validate_database!(database, marker) do
    case File.lstat(database) do
      {:ok, %File.Stat{type: :regular}} -> :ready
      {:ok, _stat} -> fail!(marker, "database file is missing or not a regular file")
      {:error, :enoent} -> fail!(marker, "database file is missing")
      {:error, reason} -> fail!(marker, "database file cannot be inspected: #{inspect(reason)}")
    end
  end

  defp write_temporary_marker!(temporary, marker) do
    case File.open(temporary, [:write, :exclusive]) do
      {:ok, file} ->
        try do
          write_and_sync_marker!(file, marker)
        after
          File.close(file)
        end

      {:error, reason} ->
        fail!(marker, "cannot create temporary marker: #{:file.format_error(reason)}")
    end
  end

  defp write_and_sync_marker!(file, marker) do
    contents = "#{@expected_version}\n"

    case IO.binwrite(file, contents) do
      :ok -> sync_marker!(file, marker)
      {:error, reason} -> fail!(marker, "cannot write marker: #{:file.format_error(reason)}")
    end
  end

  defp sync_marker!(file, marker) do
    case :file.sync(file) do
      :ok -> :ok
      {:error, reason} -> fail!(marker, "cannot sync marker: #{:file.format_error(reason)}")
    end
  end

  defp publish_marker!(temporary, marker) do
    case :file.make_link(String.to_charlist(temporary), String.to_charlist(marker)) do
      :ok ->
        :ok

      {:error, reason} ->
        fail!(marker, "cannot atomically publish marker: #{:file.format_error(reason)}")
    end
  end

  defp read_marker!(marker) do
    case File.read(marker) do
      {:ok, contents} ->
        case Regex.run(~r/\A([1-9][0-9]*)\n\z/, contents) do
          [_, version] -> String.to_integer(version)
          _ -> fail!(marker, "invalid marker contents")
        end

      {:error, reason} ->
        fail!(marker, "cannot read marker: #{:file.format_error(reason)}")
    end
  end

  defp require_initialization_mode!("backup", marker),
    do: fail!(marker, "missing application data; backup mode cannot initialize")

  defp require_initialization_mode!(_mode, _marker), do: :ok

  defp fail!(marker, reason) do
    raise "recipes storage version failure at #{marker}: expected #{@expected_version}, #{reason}"
  end
end
