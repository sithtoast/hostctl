defmodule Hostctl.FeatureSetupTest do
  use ExUnit.Case, async: true
  alias Hostctl.FeatureSetup

  @config """
  pam_service_name=vsftpd.virtual
  guest_enable=YES
  user_config_dir=/etc/vsftpd/vsftpd_user_conf
  local_enable=YES
  write_enable=YES
  chroot_local_user=YES
  anonymous_enable=NO
  """
  @pam """
  auth required pam_userdb.so db=/etc/vsftpd/virtual_users crypt=crypt
  account required pam_userdb.so db=/etc/vsftpd/virtual_users
  """

  test "a running distro FTP configuration is not ready for virtual accounts" do
    refute FeatureSetup.ftp_configuration_valid?(
             "local_enable=YES\npam_service_name=vsftpd\n",
             "@include common-auth\n"
           )
  end

  test "managed guest mappings require the matching crypt-enabled PAM stack" do
    assert FeatureSetup.ftp_configuration_valid?(@config, @pam)
    refute FeatureSetup.ftp_configuration_valid?(@config, "")

    refute FeatureSetup.ftp_configuration_valid?(
             @config,
             String.replace(@pam, " crypt=crypt", "")
           )

    refute FeatureSetup.ftp_configuration_valid?(@config <> "guest_enable=NO\n", @pam)

    refute FeatureSetup.ftp_configuration_valid?(
             String.replace(@config, "chroot_local_user=YES", "#chroot_local_user=YES"),
             @pam
           )
  end
end
