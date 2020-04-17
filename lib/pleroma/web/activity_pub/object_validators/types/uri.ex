defmodule Pleroma.Web.ActivityPub.ObjectValidators.Types.Uri do
  use Ecto.Type

  def type, do: :string

  def cast(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{host: nil} -> :error
      %URI{host: ""} -> :error
      %URI{scheme: scheme} when scheme in ["https", "http"] -> {:ok, uri}
      _ -> :error
    end
  end

  def cast(_), do: :error

  def dump(data), do: {:ok, data}

  def load(data), do: {:ok, data}
end
