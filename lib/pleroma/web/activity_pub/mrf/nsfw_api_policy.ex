# Pleroma: A lightweight social networking server
# Copyright © 2017-2021 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.MRF.NsfwApiPolicy do
  @moduledoc """
  Hide, delete, or mark sensitive NSFW content with artificial intelligence.

  Requires a NSFW API server, configured like so:

      config :pleroma, Pleroma.Web.ActivityPub.MRF.NsfwMRF,
        url: "http://127.0.0.1:5000/",
        threshold: 0.8,
        mark_sensitive: true,
        unlist: false,
        reject: false

  The NSFW API server must implement an HTTP endpoint like this:

      curl http://localhost:5000/?url=https://fedi.com/images/001.jpg

  Returning a response like this:

      {"score", 0.314}

  Where a score is 0-1, with `1` being definitely NSFW.

  A good API server is here: https://github.com/EugenCepoi/nsfw_api
  You can run it with Docker with a one-liner:

      docker run -it -p 127.0.0.1:5000:5000/tcp --env PORT=5000 eugencepoi/nsfw_api:latest

  Options:

  - `url`: Base URL of the API server. Default: "http://127.0.0.1:5000/"
  - `threshold`: Lowest score to take action on. Default: `0.7`
  - `mark_sensitive`: Mark sensitive all detected NSFW content? Default: `true`
  - `unlist`: Unlist all detected NSFW content? Default: `false`
  - `reject`: Reject all detected NSFW content (takes precedence)? Default: `false`
  """
  alias Pleroma.Config
  alias Pleroma.Constants
  alias Pleroma.HTTP
  alias Pleroma.User

  require Logger
  require Pleroma.Constants

  @behaviour Pleroma.Web.ActivityPub.MRF
  @policy :mrf_nsfw_api

  defp build_request_url(url) do
    Config.get([@policy, :url])
    |> URI.parse()
    |> Map.put(:query, "url=#{url}")
    |> URI.to_string()
  end

  defp parse_url(url) do
    request = build_request_url(url)

    with {:ok, %Tesla.Env{body: body}} <- HTTP.get(request) do
      Jason.decode(body)
    else
      error ->
        Logger.warn("""
        [NsfwApiPolicy]: The API server failed. Skipping.
        #{inspect(error)}
        """)

        error
    end
  end

  defp check_url_nsfw(url) when is_binary(url) do
    threshold = Config.get([@policy, :threshold])

    case parse_url(url) do
      {:ok, %{"score" => score}} when score >= threshold ->
        {:nsfw, %{url: url, score: score, threshold: threshold}}

      _ ->
        {:sfw, url}
    end
  end

  defp check_url_nsfw(%{"href" => url}) when is_binary(url) do
    check_url_nsfw(url)
  end

  defp check_attachment_nsfw(%{"url" => urls} = attachment) when is_list(urls) do
    if Enum.all?(urls, &match?({:sfw, _}, check_url_nsfw(&1))) do
      {:sfw, attachment}
    else
      {:nsfw, attachment}
    end
  end

  defp check_object_nsfw(%{"attachment" => attachments} = object) when is_list(attachments) do
    if Enum.all?(attachments, &match?({:sfw, _}, check_attachment_nsfw(&1))) do
      {:sfw, object}
    else
      {:nsfw, object}
    end
  end

  defp check_object_nsfw(%{"object" => %{} = child_object} = object) do
    case check_object_nsfw(child_object) do
      {:sfw, _} -> {:sfw, object}
      {:nsfw, _} -> {:nsfw, object}
    end
  end

  defp check_object_nsfw(object), do: {:sfw, object}

  @impl true
  def filter(object) do
    with {:sfw, object} <- check_object_nsfw(object) do
      {:ok, object}
    else
      {:nsfw, _data} -> handle_nsfw(object)
      _ -> {:reject, "NSFW: Attachment rejected"}
    end
  end

  defp handle_nsfw(object) do
    if Config.get([@policy, :reject]) do
      {:reject, object}
    else
      {:ok,
       object
       |> maybe_unlist()
       |> maybe_mark_sensitive()}
    end
  end

  defp maybe_unlist(object) do
    if Config.get([@policy, :unlist]) do
      unlist(object)
    else
      object
    end
  end

  defp maybe_mark_sensitive(object) do
    if Config.get([@policy, :mark_sensitive]) do
      mark_sensitive(object)
    else
      object
    end
  end

  defp unlist(%{"to" => to, "cc" => cc, "actor" => actor} = object) do
    with %User{} = user <- User.get_cached_by_ap_id(actor) do
      to =
        [user.follower_address | to]
        |> List.delete(Constants.as_public())
        |> Enum.uniq()

      cc =
        [Constants.as_public() | cc]
        |> List.delete(user.follower_address)
        |> Enum.uniq()

      object
      |> Map.put("to", to)
      |> Map.put("cc", cc)
    else
      _ -> raise "[NsfwApiPolicy]: Could not fetch user #{actor}"
    end
  end

  defp mark_sensitive(%{"object" => child_object} = object) when is_map(child_object) do
    Map.put(object, "object", mark_sensitive(child_object))
  end

  defp mark_sensitive(object) when is_map(object) do
    tags = (object["tag"] || []) ++ ["nsfw"]

    object
    |> Map.put("tag", tags)
    |> Map.put("sensitive", true)
  end

  @impl true
  def describe, do: {:ok, %{}}
end
