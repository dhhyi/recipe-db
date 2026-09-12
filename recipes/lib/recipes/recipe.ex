defmodule Recipes.Recipe do
  @moduledoc """
  Validates recipe documents and applies JSON Merge Patch updates.
  """

  @type document :: %{String.t() => Jason.OrderedObject.value()}

  @spec new_id() :: String.t()
  def new_id, do: Uniq.UUID.uuid4()

  @spec validate(document()) :: :ok | {:error, atom(), String.t(), String.t() | nil}
  def validate(document) when is_map(document) do
    cond do
      Map.has_key?(document, "id") ->
        {:error, :reserved_field, "Reserved field: id", "id"}

      valid_name?(Map.get(document, "name")) ->
        :ok

      true ->
        {:error, :required_field, "Missing field value for name", "name"}
    end
  end

  def validate(_document), do: {:error, :invalid_json_object, "Expected a JSON object", nil}

  @spec validate_patch(document()) :: :ok | {:error, atom(), String.t(), String.t() | nil}
  def validate_patch(patch) when is_map(patch) do
    if Map.has_key?(patch, "id") do
      {:error, :reserved_field, "Reserved field: id", "id"}
    else
      :ok
    end
  end

  def validate_patch(_patch), do: {:error, :invalid_json_object, "Expected a JSON object", nil}

  @spec merge_patch(Jason.OrderedObject.value(), Jason.OrderedObject.value()) ::
          Jason.OrderedObject.value()
  def merge_patch(target, patch) when is_map(patch) do
    target = if is_map(target), do: target, else: %{}

    Enum.reduce(patch, target, fn
      {key, nil}, result -> Map.delete(result, key)
      {key, value}, result -> Map.put(result, key, merge_patch(Map.get(result, key), value))
    end)
  end

  def merge_patch(_target, patch), do: patch

  defp valid_name?(name), do: is_binary(name) and String.trim(name) != ""
end
