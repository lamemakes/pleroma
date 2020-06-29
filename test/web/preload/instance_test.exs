# Pleroma: A lightweight social networking server
# Copyright © 2017-2020 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Preload.Providers.InstanceTest do
  use Pleroma.DataCase
  alias Pleroma.Web.Preload.Providers.Instance

  setup do: {:ok, Instance.generate_terms(nil)}

  test "it renders the info", %{"/api/v1/instance" => info} do
    assert %{
             description: description,
             email: "admin@example.com",
             registrations: true
           } = info

    assert String.equivalent?(description, "Pleroma: An efficient and flexible fediverse server")
  end

  test "it renders the panel", %{"/instance/panel.html" => panel} do
    assert String.contains?(
             panel,
             "<p>Welcome to <a href=\"https://pleroma.social\" target=\"_blank\">Pleroma!</a></p>"
           )
  end

  test "it renders the node_info", %{"/nodeinfo/2.0.json" => nodeinfo} do
    %{
      metadata: metadata,
      version: "2.0"
    } = nodeinfo

    assert metadata.private == false
    assert metadata.suggestions == %{enabled: false}
  end
end
