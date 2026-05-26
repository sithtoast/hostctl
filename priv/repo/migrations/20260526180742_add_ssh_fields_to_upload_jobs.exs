defmodule Hostctl.Repo.Migrations.AddSshFieldsToUploadJobs do
  use Ecto.Migration

  def change do
    alter table(:upload_jobs) do
      # Remote source path on the Plesk server — stored so the background worker
      # can do its own batched rsync without needing the files pre-staged.
      add :remote_source_path, :string
      add :ssh_host, :string
      add :ssh_port, :string
      add :ssh_username, :string
      add :ssh_auth_method, :string
      add :ssh_private_key_path, :string
      # Encrypted — same EncryptedField used for s3_secret_access_key
      add :ssh_password, :binary
    end
  end
end
