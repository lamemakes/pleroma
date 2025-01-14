# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.User.BackupTest do
  use Oban.Testing, repo: Pleroma.Repo
  use Pleroma.DataCase

  import Mock
  import Pleroma.Factory
  import Swoosh.TestAssertions
  import Mox

  alias Pleroma.Bookmark
  alias Pleroma.Tests.ObanHelpers
  alias Pleroma.UnstubbedConfigMock, as: ConfigMock
  alias Pleroma.Uploaders.S3.ExAwsMock
  alias Pleroma.User.Backup
  alias Pleroma.User.Backup.ProcessorMock
  alias Pleroma.Web.CommonAPI
  alias Pleroma.Workers.BackupWorker

  setup do
    clear_config([Pleroma.Upload, :uploader])
    clear_config([Backup, :limit_days])
    clear_config([Pleroma.Emails.Mailer, :enabled], true)

    ConfigMock
    |> stub_with(Pleroma.Config)

    ProcessorMock
    |> stub_with(Pleroma.User.Backup.Processor)

    :ok
  end

  test "it does not requrie enabled email" do
    clear_config([Pleroma.Emails.Mailer, :enabled], false)
    user = insert(:user)
    assert {:ok, _} = Backup.create(user)
  end

  test "it does not require user's email" do
    user = insert(:user, %{email: nil})
    assert {:ok, _} = Backup.create(user)
  end

  test "it creates a backup record and an Oban job" do
    %{id: user_id} = user = insert(:user)
    assert {:ok, %Oban.Job{args: args}} = Backup.create(user)
    assert_enqueued(worker: BackupWorker, args: args)

    backup = Backup.get(args["backup_id"])
    assert %Backup{user_id: ^user_id, processed: false, file_size: 0, state: :pending} = backup
  end

  test "it return an error if the export limit is over" do
    %{id: user_id} = user = insert(:user)
    limit_days = Pleroma.Config.get([Backup, :limit_days])
    assert {:ok, %Oban.Job{args: args}} = Backup.create(user)
    backup = Backup.get(args["backup_id"])
    assert %Backup{user_id: ^user_id, processed: false, file_size: 0} = backup

    assert Backup.create(user) == {:error, "Last export was less than #{limit_days} days ago"}
  end

  test "it process a backup record" do
    clear_config([Pleroma.Upload, :uploader], Pleroma.Uploaders.Local)
    %{id: user_id} = user = insert(:user)

    assert {:ok, %Oban.Job{args: %{"backup_id" => backup_id} = args}} = Backup.create(user)
    assert {:ok, backup} = perform_job(BackupWorker, args)
    assert backup.file_size > 0
    assert %Backup{id: ^backup_id, processed: true, user_id: ^user_id, state: :complete} = backup

    delete_job_args = %{"op" => "delete", "backup_id" => backup_id}

    assert_enqueued(worker: BackupWorker, args: delete_job_args)
    assert {:ok, backup} = perform_job(BackupWorker, delete_job_args)
    refute Backup.get(backup_id)

    email = Pleroma.Emails.UserEmail.backup_is_ready_email(backup)

    assert_email_sent(
      to: {user.name, user.email},
      html_body: email.html_body
    )
  end

  test "it updates states of the backup" do
    clear_config([Pleroma.Upload, :uploader], Pleroma.Uploaders.Local)
    %{id: user_id} = user = insert(:user)

    assert {:ok, %Oban.Job{args: %{"backup_id" => backup_id} = args}} = Backup.create(user)
    assert {:ok, backup} = perform_job(BackupWorker, args)
    assert backup.file_size > 0
    assert %Backup{id: ^backup_id, processed: true, user_id: ^user_id, state: :complete} = backup

    delete_job_args = %{"op" => "delete", "backup_id" => backup_id}

    assert_enqueued(worker: BackupWorker, args: delete_job_args)
    assert {:ok, backup} = perform_job(BackupWorker, delete_job_args)
    refute Backup.get(backup_id)

    email = Pleroma.Emails.UserEmail.backup_is_ready_email(backup)

    assert_email_sent(
      to: {user.name, user.email},
      html_body: email.html_body
    )
  end

  test "it does not send an email if the user does not have an email" do
    clear_config([Pleroma.Upload, :uploader], Pleroma.Uploaders.Local)
    %{id: user_id} = user = insert(:user, %{email: nil})

    assert {:ok, %Oban.Job{args: %{"backup_id" => backup_id} = args}} = Backup.create(user)
    assert {:ok, backup} = perform_job(BackupWorker, args)
    assert backup.file_size > 0
    assert %Backup{id: ^backup_id, processed: true, user_id: ^user_id} = backup

    assert_no_email_sent()
  end

  test "it does not send an email if mailer is not on" do
    clear_config([Pleroma.Emails.Mailer, :enabled], false)
    clear_config([Pleroma.Upload, :uploader], Pleroma.Uploaders.Local)
    %{id: user_id} = user = insert(:user)

    assert {:ok, %Oban.Job{args: %{"backup_id" => backup_id} = args}} = Backup.create(user)
    assert {:ok, backup} = perform_job(BackupWorker, args)
    assert backup.file_size > 0
    assert %Backup{id: ^backup_id, processed: true, user_id: ^user_id} = backup

    assert_no_email_sent()
  end

  test "it does not send an email if the user has an empty email" do
    clear_config([Pleroma.Upload, :uploader], Pleroma.Uploaders.Local)
    %{id: user_id} = user = insert(:user, %{email: ""})

    assert {:ok, %Oban.Job{args: %{"backup_id" => backup_id} = args}} = Backup.create(user)
    assert {:ok, backup} = perform_job(BackupWorker, args)
    assert backup.file_size > 0
    assert %Backup{id: ^backup_id, processed: true, user_id: ^user_id} = backup

    assert_no_email_sent()
  end

  test "it removes outdated backups after creating a fresh one" do
    clear_config([Backup, :limit_days], -1)
    clear_config([Pleroma.Upload, :uploader], Pleroma.Uploaders.Local)
    user = insert(:user)

    assert {:ok, job1} = Backup.create(user)

    assert {:ok, %Backup{}} = ObanHelpers.perform(job1)
    assert {:ok, job2} = Backup.create(user)
    assert Pleroma.Repo.aggregate(Backup, :count) == 2
    assert {:ok, backup2} = ObanHelpers.perform(job2)

    ObanHelpers.perform_all()

    assert [^backup2] = Pleroma.Repo.all(Backup)
  end

  test "it creates a zip archive with user data" do
    user = insert(:user, %{nickname: "cofe", name: "Cofe", ap_id: "http://cofe.io/users/cofe"})
    %{ap_id: other_ap_id} = other_user = insert(:user)

    {:ok, %{object: %{data: %{"id" => id1}}} = status1} =
      CommonAPI.post(user, %{status: "status1"})

    {:ok, %{object: %{data: %{"id" => id2}}} = status2} =
      CommonAPI.post(user, %{status: "status2"})

    {:ok, %{object: %{data: %{"id" => id3}}} = status3} =
      CommonAPI.post(user, %{status: "status3"})

    CommonAPI.favorite(user, status1.id)
    CommonAPI.favorite(user, status2.id)

    Bookmark.create(user.id, status2.id)
    Bookmark.create(user.id, status3.id)

    CommonAPI.follow(user, other_user)

    assert {:ok, backup} = user |> Backup.new() |> Repo.insert()
    assert {:ok, path} = Backup.export(backup, self())
    assert {:ok, zipfile} = :zip.zip_open(String.to_charlist(path), [:memory])
    assert {:ok, {'actor.json', json}} = :zip.zip_get('actor.json', zipfile)

    assert %{
             "@context" => [
               "https://www.w3.org/ns/activitystreams",
               "http://localhost:4001/schemas/litepub-0.1.jsonld",
               %{"@language" => "und"}
             ],
             "bookmarks" => "bookmarks.json",
             "followers" => "http://cofe.io/users/cofe/followers",
             "following" => "http://cofe.io/users/cofe/following",
             "id" => "http://cofe.io/users/cofe",
             "inbox" => "http://cofe.io/users/cofe/inbox",
             "likes" => "likes.json",
             "name" => "Cofe",
             "outbox" => "http://cofe.io/users/cofe/outbox",
             "preferredUsername" => "cofe",
             "publicKey" => %{
               "id" => "http://cofe.io/users/cofe#main-key",
               "owner" => "http://cofe.io/users/cofe"
             },
             "type" => "Person",
             "url" => "http://cofe.io/users/cofe"
           } = Jason.decode!(json)

    assert {:ok, {'outbox.json', json}} = :zip.zip_get('outbox.json', zipfile)

    assert %{
             "@context" => "https://www.w3.org/ns/activitystreams",
             "id" => "outbox.json",
             "orderedItems" => [
               %{
                 "object" => %{
                   "actor" => "http://cofe.io/users/cofe",
                   "content" => "status1",
                   "type" => "Note"
                 },
                 "type" => "Create"
               },
               %{
                 "object" => %{
                   "actor" => "http://cofe.io/users/cofe",
                   "content" => "status2"
                 }
               },
               %{
                 "actor" => "http://cofe.io/users/cofe",
                 "object" => %{
                   "content" => "status3"
                 }
               }
             ],
             "totalItems" => 3,
             "type" => "OrderedCollection"
           } = Jason.decode!(json)

    assert {:ok, {'likes.json', json}} = :zip.zip_get('likes.json', zipfile)

    assert %{
             "@context" => "https://www.w3.org/ns/activitystreams",
             "id" => "likes.json",
             "orderedItems" => [^id1, ^id2],
             "totalItems" => 2,
             "type" => "OrderedCollection"
           } = Jason.decode!(json)

    assert {:ok, {'bookmarks.json', json}} = :zip.zip_get('bookmarks.json', zipfile)

    assert %{
             "@context" => "https://www.w3.org/ns/activitystreams",
             "id" => "bookmarks.json",
             "orderedItems" => [^id2, ^id3],
             "totalItems" => 2,
             "type" => "OrderedCollection"
           } = Jason.decode!(json)

    assert {:ok, {'following.json', json}} = :zip.zip_get('following.json', zipfile)

    assert %{
             "@context" => "https://www.w3.org/ns/activitystreams",
             "id" => "following.json",
             "orderedItems" => [^other_ap_id],
             "totalItems" => 1,
             "type" => "OrderedCollection"
           } = Jason.decode!(json)

    :zip.zip_close(zipfile)
    File.rm!(path)
  end

  test "it counts the correct number processed" do
    user = insert(:user, %{nickname: "cofe", name: "Cofe", ap_id: "http://cofe.io/users/cofe"})

    Enum.map(1..120, fn i ->
      {:ok, status} = CommonAPI.post(user, %{status: "status #{i}"})
      CommonAPI.favorite(user, status.id)
      Bookmark.create(user.id, status.id)
    end)

    assert {:ok, backup} = user |> Backup.new() |> Repo.insert()
    {:ok, backup} = Backup.process(backup)

    assert backup.processed_number == 1 + 120 + 120 + 120

    Backup.delete(backup)
  end

  test "it handles errors" do
    user = insert(:user, %{nickname: "cofe", name: "Cofe", ap_id: "http://cofe.io/users/cofe"})

    Enum.map(1..120, fn i ->
      {:ok, _status} = CommonAPI.post(user, %{status: "status #{i}"})
    end)

    assert {:ok, backup} = user |> Backup.new() |> Repo.insert()

    with_mock Pleroma.Web.ActivityPub.Transmogrifier,
              [:passthrough],
              prepare_outgoing: fn data ->
                object =
                  data["object"]
                  |> Pleroma.Object.normalize(fetch: false)
                  |> Map.get(:data)

                data = data |> Map.put("object", object)

                if String.contains?(data["object"]["content"], "119"),
                  do: raise(%Postgrex.Error{}),
                  else: {:ok, data}
              end do
      {:ok, backup} = Backup.process(backup)
      assert backup.processed
      assert backup.state == :complete
      assert backup.processed_number == 1 + 119

      Backup.delete(backup)
    end
  end

  describe "it uploads and deletes a backup archive" do
    setup do
      clear_config([Pleroma.Upload, :base_url], "https://s3.amazonaws.com")
      clear_config([Pleroma.Uploaders.S3, :bucket], "test_bucket")

      user = insert(:user, %{nickname: "cofe", name: "Cofe", ap_id: "http://cofe.io/users/cofe"})

      {:ok, status1} = CommonAPI.post(user, %{status: "status1"})
      {:ok, status2} = CommonAPI.post(user, %{status: "status2"})
      {:ok, status3} = CommonAPI.post(user, %{status: "status3"})
      CommonAPI.favorite(user, status1.id)
      CommonAPI.favorite(user, status2.id)
      Bookmark.create(user.id, status2.id)
      Bookmark.create(user.id, status3.id)

      assert {:ok, backup} = user |> Backup.new() |> Repo.insert()
      assert {:ok, path} = Backup.export(backup, self())

      [path: path, backup: backup]
    end

    test "S3", %{path: path, backup: backup} do
      clear_config([Pleroma.Upload, :uploader], Pleroma.Uploaders.S3)
      clear_config([Pleroma.Uploaders.S3, :streaming_enabled], false)

      ExAwsMock
      |> expect(:request, 2, fn
        %{http_method: :put} -> {:ok, :ok}
        %{http_method: :delete} -> {:ok, %{status_code: 204}}
      end)

      assert {:ok, %Pleroma.Upload{}} = Backup.upload(backup, path)
      assert {:ok, _backup} = Backup.delete(backup)
    end

    test "Local", %{path: path, backup: backup} do
      clear_config([Pleroma.Upload, :uploader], Pleroma.Uploaders.Local)

      assert {:ok, %Pleroma.Upload{}} = Backup.upload(backup, path)
      assert {:ok, _backup} = Backup.delete(backup)
    end
  end
end
