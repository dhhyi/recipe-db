defmodule Recipes.Recipe do
  @moduledoc """
  Validates recipe documents and applies JSON Merge Patch updates.
  """

  @type document :: %{String.t() => Jason.OrderedObject.value()}
  @core_fields ["name", "ingredients", "method"]

  @spec new_id() :: String.t()
  def new_id, do: Uniq.UUID.uuid4()

  @spec validate(document()) :: :ok | {:error, atom(), String.t(), String.t() | nil}
  def validate(document) when is_map(document) do
    with :ok <- validate_reserved_fields(document) do
      if valid_name?(Map.get(document, "name")) do
        :ok
      else
        {:error, :required_field, "Missing field value for name", "name"}
      end
    end
  end

  def validate(_document), do: {:error, :invalid_json_object, "Expected a JSON object", nil}

  @spec validate_patch(document()) :: :ok | {:error, atom(), String.t(), String.t() | nil}
  def validate_patch(patch) when is_map(patch), do: validate_reserved_fields(patch)

  def validate_patch(_patch), do: {:error, :invalid_json_object, "Expected a JSON object", nil}

  @spec validate_reserved_fields(document()) ::
          :ok | {:error, atom(), String.t(), String.t() | nil}
  def validate_reserved_fields(document) when is_map(document) do
    case Enum.find(["id", "createdAt", "updatedAt", "nameSortKey"], &Map.has_key?(document, &1)) do
      nil -> :ok
      field -> {:error, :reserved_field, "Reserved field: #{field}", field}
    end
  end

  def validate_reserved_fields(_document),
    do: {:error, :invalid_json_object, "Expected a JSON object", nil}

  @spec with_derived_fields(document()) :: document()
  def with_derived_fields(document) do
    Map.put(document, "nameSortKey", name_sort_key(Map.fetch!(document, "name")))
  end

  @spec name_sort_key(String.t()) :: String.t()
  def name_sort_key(name) do
    name
    |> String.trim()
    |> String.normalize(:nfc)
    |> String.downcase()
    |> String.replace("ä", "a")
    |> String.replace("ö", "o")
    |> String.replace("ü", "u")
    |> String.replace("ß", "ss")
  end

  @spec core_changed?(document(), document()) :: boolean()
  def core_changed?(before_document, after_document) do
    Enum.any?(
      @core_fields,
      &(Map.get(before_document, &1) != Map.get(after_document, &1))
    )
  end

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
