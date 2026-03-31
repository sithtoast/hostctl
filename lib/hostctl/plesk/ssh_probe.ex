defmodule Hostctl.Plesk.SSHProbe do
  @moduledoc """
  SSH-backed discovery helpers for gathering Plesk inventory directly from a remote server.

  Discovery focuses on subscription/domain inventory first and layers in additional
  data categories when requested.
  """

  @inventory_keys [
    "dns",
    "web_files",
    "mail_accounts",
    "mail_content",
    "databases",
    "db_users",
    "cron_jobs",
    "ftp_accounts",
    "ssl_certificates",
    "system_users"
  ]

  @type subscription :: %{
          domain: String.t(),
          owner_login: String.t() | nil,
          owner_type: String.t() | nil,
          system_user: String.t() | nil
        }

  @type discovery :: %{
          subscriptions: [subscription()],
          inventory: %{optional(String.t()) => [map()]},
          warnings: [String.t()]
        }

  @doc """
  Discovers subscriptions and optional inventory categories from a remote Plesk host over SSH.

  Required opts:
    - `:host`
    - `:port`
    - `:username`

  Authentication:
    - `:auth_method` can be `"key"` or `"password"`
    - `:private_key_path` is required when auth method is key
    - `:password` is required when auth method is password

  Returns:
    - `{:ok, discovery()}`
    - `{:error, reason}`
  """
  def discover(opts, selected_data_types \\ ["domains"]) when is_map(opts) do
    with :ok <- validate_opts(opts),
         {:ok, data_types} <- validate_data_types(selected_data_types),
         {:ok, output} <- run_probe(opts, data_types),
         {:ok, discovery} <- parse_probe_output(output) do
      {:ok, discovery}
    end
  end

  @doc false
  def parse_subscriptions_output(output) when is_binary(output) do
    with {:ok, %{subscriptions: subscriptions}} <- parse_probe_output(output) do
      {:ok, subscriptions}
    end
  end

  @doc false
  def parse_probe_output(output) when is_binary(output) do
    initial = %{subscriptions: [], inventory: empty_inventory(), warnings: []}

    result =
      output
      |> String.split("\n", trim: true)
      |> Enum.reduce_while({:ok, initial}, fn line, {:ok, acc} ->
        case parse_probe_line(line) do
          {:ok, update} -> {:cont, {:ok, update.(acc)}}
          :ignore -> {:cont, {:ok, acc}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    with {:ok, %{subscriptions: subscriptions} = discovery} <- result do
      subscriptions =
        subscriptions
        |> Enum.uniq_by(& &1.domain)
        |> Enum.sort_by(& &1.domain)

      discovery = %{
        discovery
        | subscriptions: subscriptions,
          inventory: normalize_inventory(discovery.inventory),
          warnings: Enum.reverse(discovery.warnings)
      }

      if subscriptions == [] do
        snippet =
          output
          |> String.trim()
          |> String.slice(0, 400)

        if snippet == "" do
          {:error, "No subscriptions were discovered from remote Plesk host."}
        else
          {:error,
           "No subscriptions were discovered from remote Plesk host. Probe output: #{snippet}"}
        end
      else
        {:ok, discovery}
      end
    end
  end

  defp validate_opts(opts) do
    host = normalize_string(Map.get(opts, :host) || Map.get(opts, "host"))
    port = normalize_string(Map.get(opts, :port) || Map.get(opts, "port"))
    username = normalize_string(Map.get(opts, :username) || Map.get(opts, "username"))
    auth_method = normalize_string(Map.get(opts, :auth_method) || Map.get(opts, "auth_method"))

    cond do
      host == "" ->
        {:error, "SSH host is required for SSH source."}

      username == "" ->
        {:error, "SSH username is required for SSH source."}

      port == "" ->
        {:error, "SSH port is required for SSH source."}

      not String.match?(port, ~r/^\d+$/) ->
        {:error, "SSH port must be numeric."}

      auth_method != "key" ->
        if auth_method == "password" do
          if normalize_string(Map.get(opts, :password) || Map.get(opts, "password")) == "" do
            {:error, "SSH password is required when auth method is password."}
          else
            :ok
          end
        else
          {:error, "SSH auth method must be key or password."}
        end

      normalize_string(Map.get(opts, :private_key_path) || Map.get(opts, "private_key_path")) ==
          "" ->
        {:error, "SSH private key path is required when auth method is key."}

      true ->
        :ok
    end
  end

  defp validate_data_types(selected_data_types) when is_list(selected_data_types) do
    data_types =
      selected_data_types
      |> Enum.map(&normalize_string/1)
      |> Enum.reject(&(&1 == "" or &1 == "domains"))
      |> Enum.uniq()

    invalid = Enum.reject(data_types, &(&1 in @inventory_keys))

    if invalid == [] do
      {:ok, data_types}
    else
      {:error, "Unsupported SSH discovery types: #{Enum.join(invalid, ", ")}"}
    end
  end

  defp validate_data_types(_), do: {:ok, []}

  defp run_probe(opts, data_types) do
    auth_method = normalize_string(Map.get(opts, :auth_method) || Map.get(opts, "auth_method"))
    command = probe_cmd(data_types)

    case auth_method do
      "password" -> run_probe_password(opts, command)
      _ -> run_probe_key(opts, command)
    end
  end

  defp run_probe_key(opts, command) do
    ssh = System.find_executable("ssh") || "ssh"

    host = normalize_string(Map.get(opts, :host) || Map.get(opts, "host"))
    port = normalize_string(Map.get(opts, :port) || Map.get(opts, "port"))
    username = normalize_string(Map.get(opts, :username) || Map.get(opts, "username"))

    private_key_path =
      opts
      |> Map.get(:private_key_path, Map.get(opts, "private_key_path"))
      |> normalize_string()
      |> expand_tilde_path()

    remote = "#{username}@#{host}"

    args = [
      "-p",
      port,
      "-o",
      "BatchMode=yes",
      "-o",
      "ConnectTimeout=8",
      "-o",
      "StrictHostKeyChecking=accept-new",
      "-i",
      private_key_path,
      remote,
      command
    ]

    case System.cmd(ssh, args, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, output}

      {output, _code} ->
        {:error, "SSH discovery failed: #{output}"}
    end
  end

  defp run_probe_password(opts, command) do
    host = normalize_string(Map.get(opts, :host) || Map.get(opts, "host"))
    port = normalize_port(Map.get(opts, :port) || Map.get(opts, "port"))
    username = normalize_string(Map.get(opts, :username) || Map.get(opts, "username"))
    password = normalize_string(Map.get(opts, :password) || Map.get(opts, "password"))

    ssh_opts = [
      user: to_charlist(username),
      silently_accept_hosts: true,
      user_interaction: false,
      auth_methods: ~c"password",
      password: to_charlist(password),
      connect_timeout: 8_000
    ]

    with :ok <- ensure_otp_ssh_available(),
         {:ok, conn} <- apply(:ssh, :connect, [to_charlist(host), port, ssh_opts]),
         {:ok, channel} <- apply(:ssh_connection, :session_channel, [conn, 8_000]),
         :success <-
           apply(:ssh_connection, :exec, [
             conn,
             channel,
             to_charlist(password_probe_cmd(command)),
             8_000
           ]),
         :ok <- send_channel_input(conn, channel, password <> "\n"),
         {:ok, output} <- collect_channel_output(conn, channel, "", nil) do
      apply(:ssh, :close, [conn])
      {:ok, output}
    else
      {:error, reason} ->
        {:error, "SSH discovery failed: #{format_ssh_reason(reason)}"}

      other ->
        {:error, "SSH discovery failed: #{inspect(other)}"}
    end
  end

  defp ensure_otp_ssh_available do
    if Code.ensure_loaded?(:ssh) and Code.ensure_loaded?(:ssh_connection) do
      :ok
    else
      {:error, "OTP SSH modules are unavailable in this runtime."}
    end
  end

  defp probe_cmd(data_types) do
    extra_loop_steps = subscription_loop_steps(data_types)
    extra_query_steps = extra_query_steps(data_types)

    """
    export PATH=$PATH:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin:/usr/local/psa/bin
    TAB=$(printf '\\t')
    PLESK_BIN=
    for c in "$(command -v plesk 2>/dev/null)" /usr/sbin/plesk /usr/local/psa/bin/plesk; do
      if [ -n "$c" ] && [ -x "$c" ]; then
        PLESK_BIN="$c"
        break
      fi
    done

    if [ -z "$PLESK_BIN" ]; then
      printf 'ERR\\tplesk_not_found\\n'
      exit 0
    fi

    run_plesk() {
      if [ "$(id -u)" = "0" ]; then
        "$PLESK_BIN" "$@"
      elif sudo -n true >/dev/null 2>&1; then
        sudo -n "$PLESK_BIN" "$@"
      else
        "$PLESK_BIN" "$@"
      fi
    }

    run_root() {
      if [ "$(id -u)" = "0" ]; then
        "$@"
      elif sudo -n true >/dev/null 2>&1; then
        sudo -n "$@"
      else
        "$@"
      fi
    }

    emit_warn() {
      code="$1"
      shift
      msg=$(printf '%s' "$*" | tr '\\n' ' ' | tr '\\t' ' ')
      printf 'WARN\\t%s\\t%s\\n' "$code" "$msg"
    }

    owner_rows=$(run_plesk db -Ne "select d.name, coalesce(c.login,''), coalesce(c.type,''), coalesce(s.login,''), coalesce(h.www_root,'') from domains d left join clients c on c.id=d.cl_id left join hosting h on h.dom_id=d.id left join sys_users s on s.id=h.sys_user_id where d.name <> '' order by d.name" 2>&1)

    if [ $? -eq 0 ] && [ -n "$(printf '%s' \"$owner_rows\" | tr -d '[:space:]')" ]; then
      printf '%s\n' "$owner_rows" | while IFS="$TAB" read -r d owner owner_type sys docroot; do
        [ -z "$d" ] && continue
        printf 'SUB\t%s\t%s\t%s\t%s\n' "$d" "$owner" "$owner_type" "$sys"
    #{extra_loop_steps}
      done
    else
      emit_warn owner_query_failed "$owner_rows"

      list=$(run_plesk bin subscription --list 2>&1)
      if [ $? -ne 0 ]; then
        printf 'ERR\tsubscription_list_failed\t%s\n' "$(printf '%s' \"$list\" | tr '\n' ' ' | tr '\t' ' ')"
        exit 0
      fi

      if [ -z "$(printf '%s' \"$list\" | tr -d '[:space:]')" ]; then
        printf 'ERR\tsubscription_list_empty\n'
        exit 0
      fi

      printf '%s\n' "$list" | while IFS= read -r d; do
        [ -z "$d" ] && continue
        info=$(run_plesk bin subscription --info "$d" 2>&1)

        if [ $? -ne 0 ]; then
          emit_warn subscription_info_failed "$d: $info"
          continue
        fi

        owner=$(printf '%s\n' "$info" | awk 'BEGIN{IGNORECASE=1} /^[[:space:]]*Owner([[:space:]]+login)?[[:space:]]*:/ {line=$0; sub(/^[^:]*:[[:space:]]*/, "", line); gsub(/^[[:space:]]+|[[:space:]]+$/, "", line); print line; exit}')
        owner_type=$(printf '%s\n' "$info" | awk 'BEGIN{IGNORECASE=1} /^[[:space:]]*Owner[[:space:]]+type[[:space:]]*:/ {line=$0; sub(/^[^:]*:[[:space:]]*/, "", line); gsub(/^[[:space:]]+|[[:space:]]+$/, "", line); print line; exit}')
        sys=$(printf '%s\n' "$info" | awk 'BEGIN{IGNORECASE=1} /^[[:space:]]*System[[:space:]]+user([[:space:]]+name)?[[:space:]]*:/ {line=$0; sub(/^[^:]*:[[:space:]]*/, "", line); gsub(/^[[:space:]]+|[[:space:]]+$/, "", line); print line; exit}')
        docroot=$(printf '%s\n' "$info" | awk 'BEGIN{IGNORECASE=1} /^[[:space:]]*Document[[:space:]]+root[[:space:]]*:/ {line=$0; sub(/^[^:]*:[[:space:]]*/, "", line); gsub(/^[[:space:]]+|[[:space:]]+$/, "", line); print line; exit}')

        printf 'SUB\t%s\t%s\t%s\t%s\n' "$d" "$owner" "$owner_type" "$sys"
    #{extra_loop_steps}
      done
    fi

    #{extra_query_steps}
    """
  end

  defp password_probe_cmd(command) do
    quoted = shell_single_quote(command)

    "if [ \"$(id -u)\" = \"0\" ]; then /bin/sh -lc #{quoted}; " <>
      "else sudo -S -p '' /bin/sh -lc #{quoted}; fi"
  end

  defp subscription_loop_steps(data_types) do
    []
    |> maybe_append_step(
      "web_files" in data_types,
      "      if [ -n \"$docroot\" ]; then printf 'WEB\\t%s\\t%s\\t%s\\n' \"$d\" \"$sys\" \"$docroot\"; fi"
    )
    |> maybe_append_step(
      "system_users" in data_types,
      "      if [ -n \"$sys\" ]; then printf 'SYS\\t%s\\t%s\\n' \"$sys\" \"$d\"; fi"
    )
    |> maybe_append_step("dns" in data_types, dns_loop_step())
    |> maybe_append_step("ssl_certificates" in data_types, ssl_loop_step())
    |> maybe_append_step("cron_jobs" in data_types, cron_loop_step())
    |> Enum.join("\n")
  end

  defp extra_query_steps(data_types) do
    []
    |> maybe_append_step(
      "mail_accounts" in data_types or "mail_content" in data_types,
      mail_query_step(data_types)
    )
    |> maybe_append_step("databases" in data_types, database_query_step())
    |> maybe_append_step("db_users" in data_types, db_users_query_step())
    |> maybe_append_step("ftp_accounts" in data_types, ftp_query_step())
    |> Enum.join("\n\n")
  end

  defp maybe_append_step(steps, true, step), do: [step | steps]
  defp maybe_append_step(steps, false, _step), do: steps

  defp dns_loop_step do
    "      dns_info=$(run_plesk bin dns --info \"$d\" 2>&1)\n" <>
      "      if [ $? -ne 0 ]; then\n" <>
      "        if printf '%s' \"$dns_info\" | grep -qi 'DNS zone for this domain is switched off'; then\n" <>
      "          printf 'DNSOFF\\t%s\\n' \"$d\"\n" <>
      "        else\n" <>
      "          emit_warn dns_info_failed \"$d: $dns_info\"\n" <>
      "        fi\n" <>
      "      else\n" <>
      "        dns_count=$(printf '%s\\n' \"$dns_info\" | awk 'NF {count++} END {print count+0}')\n" <>
      "        printf 'DNS\\t%s\\t%s\\n' \"$d\" \"$dns_count\"\n" <>
      "      fi"
  end

  defp ssl_loop_step do
    "      certs=$(run_plesk bin certificate --list -domain \"$d\" 2>&1)\n" <>
      "      if [ $? -ne 0 ]; then\n" <>
      "        emit_warn ssl_list_failed \"$d: $certs\"\n" <>
      "      else\n" <>
      "        printf '%s\\n' \"$certs\" | while IFS= read -r cert; do\n" <>
      "          [ -z \"$cert\" ] && continue\n" <>
      "          printf 'SSL\\t%s\\t%s\\n' \"$d\" \"$cert\"\n" <>
      "        done\n" <>
      "      fi"
  end

  defp cron_loop_step do
    "      if [ -n \"$sys\" ]; then\n" <>
      "        cron_out=$(run_root crontab -l -u \"$sys\" 2>/dev/null || true)\n" <>
      "        cron_count=$(printf '%s\\n' \"$cron_out\" | sed '/^[[:space:]]*#/d;/^[[:space:]]*$/d' | wc -l | tr -d '[:space:]')\n" <>
      "        printf 'CRON\\t%s\\t%s\\t%s\\n' \"$d\" \"$sys\" \"${cron_count:-0}\"\n" <>
      "      fi"
  end

  defp mail_query_step(data_types) do
    mail_lines = [
      "mail_rows=$(run_plesk db -Ne \"select m.mail_name, d.name from mail m join domains d on d.id = m.dom_id order by d.name, m.mail_name\" 2>&1)",
      "if [ $? -ne 0 ]; then",
      "  emit_warn mail_accounts_query_failed \"$mail_rows\"",
      "else",
      "  printf '%s\\n' \"$mail_rows\" | while IFS=\"$TAB\" read -r local domain; do",
      "    [ -z \"$local\" ] && continue",
      "    [ -z \"$domain\" ] && continue",
      "    printf 'MAIL\\t%s\\t%s\\n' \"$local\" \"$domain\""
    ]

    mail_lines =
      if "mail_content" in data_types do
        mail_lines ++
          [
            "    maildir=\"/var/qmail/mailnames/$domain/$local/Maildir\"",
            "    printf 'MAILDIR\\t%s\\t%s\\t%s\\n' \"$local\" \"$domain\" \"$maildir\""
          ]
      else
        mail_lines
      end

    (mail_lines ++ ["  done", "fi"])
    |> Enum.join("\n")
  end

  defp database_query_step do
    [
      "db_rows=$(run_plesk db -Ne \"select db.name, d.name from data_bases db join domains d on d.id = db.dom_id order by d.name, db.name\" 2>&1)",
      "if [ $? -ne 0 ]; then",
      "  emit_warn databases_query_failed \"$db_rows\"",
      "else",
      "  printf '%s\\n' \"$db_rows\" | while IFS=\"$TAB\" read -r db_name domain; do",
      "    [ -z \"$db_name\" ] && continue",
      "    [ -z \"$domain\" ] && continue",
      "    printf 'DB\\t%s\\t%s\\n' \"$db_name\" \"$domain\"",
      "  done",
      "fi"
    ]
    |> Enum.join("\n")
  end

  defp db_users_query_step do
    [
      "db_user_rows=$(run_plesk db -Ne \"select u.login, db.name, d.name from db_users u join data_bases_users du on du.db_user_id = u.id join data_bases db on db.id = du.db_id join domains d on d.id = db.dom_id order by d.name, db.name, u.login\" 2>&1)",
      "if [ $? -ne 0 ]; then",
      "  db_user_rows=$(run_plesk db -Ne \"select u.login, db.name, d.name from db_users u join data_bases db on db.id = u.db_id join domains d on d.id = db.dom_id order by d.name, db.name, u.login\" 2>&1)",
      "fi",
      "if [ $? -ne 0 ]; then",
      "  emit_warn db_users_query_failed \"$db_user_rows\"",
      "else",
      "  printf '%s\\n' \"$db_user_rows\" | while IFS=\"$TAB\" read -r login db_name domain; do",
      "    [ -z \"$login\" ] && continue",
      "    [ -z \"$db_name\" ] && continue",
      "    [ -z \"$domain\" ] && continue",
      "    printf 'DBUSER\\t%s\\t%s\\t%s\\n' \"$login\" \"$db_name\" \"$domain\"",
      "  done",
      "fi"
    ]
    |> Enum.join("\n")
  end

  defp ftp_query_step do
    [
      "ftp_login_col=$(run_plesk db -Ne \"select column_name from information_schema.columns where table_schema = database() and table_name='ftp_users' and column_name in ('login','name','username','account') order by field(column_name,'login','name','username','account') limit 1\" 2>/dev/null)",
      "ftp_home_col=$(run_plesk db -Ne \"select column_name from information_schema.columns where table_schema = database() and table_name='ftp_users' and column_name in ('home','home_path','path') order by field(column_name,'home','home_path','path') limit 1\" 2>/dev/null)",
      "if [ -z \"$ftp_login_col\" ]; then",
      "  ftp_cols=$(run_plesk db -Ne \"select column_name from information_schema.columns where table_schema = database() and table_name='ftp_users' order by ordinal_position\" 2>/dev/null | paste -sd ',' -)",
      "  emit_warn ftp_accounts_schema_unsupported \"ftp_users missing known login column (columns=$ftp_cols)\"",
      "else",
      "  if [ -n \"$ftp_home_col\" ]; then",
      "    ftp_rows=$(run_plesk db -Ne \"select ${ftp_login_col}, ${ftp_home_col} from ftp_users order by ${ftp_login_col}\" 2>&1)",
      "  else",
      "    ftp_rows=$(run_plesk db -Ne \"select ${ftp_login_col}, '' from ftp_users order by ${ftp_login_col}\" 2>&1)",
      "  fi",
      "  if [ $? -ne 0 ]; then",
      "    emit_warn ftp_accounts_query_failed \"$ftp_rows\"",
      "  else",
      "    printf '%s\\n' \"$ftp_rows\" | while IFS=\"$TAB\" read -r login home; do",
      "      [ -z \"$login\" ] && continue",
      "      domain=$(printf '%s' \"$home\" | awk -F/ '/\/var\/www\/vhosts\// {print $5; exit}')",
      "      printf 'FTP\\t%s\\t%s\\n' \"$login\" \"$domain\"",
      "    done",
      "  fi",
      "fi"
    ]
    |> Enum.join("\n")
  end

  defp parse_probe_line("SUB\t" <> rest) do
    case String.split(rest, "\t", parts: 4) do
      [domain, owner_login, owner_type, system_user] ->
        if present_string?(domain) do
          {:ok,
           fn acc ->
             Map.update!(acc, :subscriptions, fn subscriptions ->
               [
                 %{
                   domain: String.trim(domain),
                   owner_login: normalize_blank(owner_login),
                   owner_type: normalize_blank(owner_type),
                   system_user: normalize_blank(system_user)
                 }
                 | subscriptions
               ]
             end)
           end}
        else
          :ignore
        end

      [domain, owner_login, system_user] ->
        if present_string?(domain) do
          {:ok,
           fn acc ->
             Map.update!(acc, :subscriptions, fn subscriptions ->
               [
                 %{
                   domain: String.trim(domain),
                   owner_login: normalize_blank(owner_login),
                   owner_type: nil,
                   system_user: normalize_blank(system_user)
                 }
                 | subscriptions
               ]
             end)
           end}
        else
          :ignore
        end

      _ ->
        :ignore
    end
  end

  defp parse_probe_line("DNS\t" <> rest) do
    case String.split(rest, "\t", parts: 2) do
      [domain, record_count] ->
        if present_string?(domain) do
          {:ok,
           &put_inventory_item(&1, "dns", %{
             domain: String.trim(domain),
             enabled: true,
             record_count: normalize_count(record_count)
           })}
        else
          :ignore
        end

      _ ->
        :ignore
    end
  end

  defp parse_probe_line("DNSOFF\t" <> rest) do
    domain = String.trim(rest)

    if present_string?(domain) do
      {:ok,
       &put_inventory_item(&1, "dns", %{
         domain: domain,
         enabled: false,
         record_count: 0
       })}
    else
      :ignore
    end
  end

  defp parse_probe_line("WEB\t" <> rest) do
    case String.split(rest, "\t", parts: 3) do
      [domain, system_user, document_root] ->
        if present_string?(domain) do
          {:ok,
           &put_inventory_item(&1, "web_files", %{
             domain: String.trim(domain),
             system_user: normalize_blank(system_user),
             document_root: normalize_blank(document_root)
           })}
        else
          :ignore
        end

      _ ->
        :ignore
    end
  end

  defp parse_probe_line("MAIL\t" <> rest) do
    case String.split(rest, "\t", parts: 2) do
      [local, domain] ->
        if present_string?(local) and present_string?(domain) do
          {:ok,
           &put_inventory_item(&1, "mail_accounts", %{
             domain: String.trim(domain),
             address: String.trim(local) <> "@" <> String.trim(domain)
           })}
        else
          :ignore
        end

      _ ->
        :ignore
    end
  end

  defp parse_probe_line("MAILDIR\t" <> rest) do
    case String.split(rest, "\t", parts: 3) do
      [local, domain, path] ->
        if present_string?(local) and present_string?(domain) and present_string?(path) do
          {:ok,
           &put_inventory_item(&1, "mail_content", %{
             domain: String.trim(domain),
             address: String.trim(local) <> "@" <> String.trim(domain),
             path: String.trim(path)
           })}
        else
          :ignore
        end

      _ ->
        :ignore
    end
  end

  defp parse_probe_line("DB\t" <> rest) do
    case String.split(rest, "\t", parts: 2) do
      [name, domain] ->
        if present_string?(name) and present_string?(domain) do
          {:ok,
           &put_inventory_item(&1, "databases", %{
             domain: String.trim(domain),
             name: String.trim(name)
           })}
        else
          :ignore
        end

      _ ->
        :ignore
    end
  end

  defp parse_probe_line("DBUSER\t" <> rest) do
    case String.split(rest, "\t", parts: 3) do
      [login, database, domain] ->
        if present_string?(login) and present_string?(database) and present_string?(domain) do
          {:ok,
           &put_inventory_item(&1, "db_users", %{
             domain: String.trim(domain),
             database: String.trim(database),
             login: String.trim(login)
           })}
        else
          :ignore
        end

      _ ->
        :ignore
    end
  end

  defp parse_probe_line("CRON\t" <> rest) do
    case String.split(rest, "\t", parts: 3) do
      [domain, system_user, count] ->
        if present_string?(domain) do
          {:ok,
           &put_inventory_item(&1, "cron_jobs", %{
             domain: String.trim(domain),
             system_user: normalize_blank(system_user),
             count: normalize_count(count)
           })}
        else
          :ignore
        end

      _ ->
        :ignore
    end
  end

  defp parse_probe_line("FTP\t" <> rest) do
    case String.split(rest, "\t", parts: 2) do
      [login, domain] ->
        if present_string?(login) do
          {:ok,
           &put_inventory_item(&1, "ftp_accounts", %{
             domain: normalize_blank(domain),
             login: String.trim(login)
           })}
        else
          :ignore
        end

      _ ->
        :ignore
    end
  end

  defp parse_probe_line("SSL\t" <> rest) do
    case String.split(rest, "\t", parts: 2) do
      [domain, name] ->
        if present_string?(domain) and present_string?(name) do
          {:ok,
           &put_inventory_item(&1, "ssl_certificates", %{
             domain: String.trim(domain),
             name: String.trim(name)
           })}
        else
          :ignore
        end

      _ ->
        :ignore
    end
  end

  defp parse_probe_line("SYS\t" <> rest) do
    case String.split(rest, "\t", parts: 2) do
      [login, domain] ->
        if present_string?(login) do
          {:ok,
           &put_inventory_item(&1, "system_users", %{
             domain: normalize_blank(domain),
             login: String.trim(login)
           })}
        else
          :ignore
        end

      _ ->
        :ignore
    end
  end

  defp parse_probe_line("WARN\t" <> rest) do
    parts = String.split(rest, "\t", parts: 2)

    warning =
      case parts do
        [code, message] ->
          if present_string?(message) do
            "#{String.trim(code)}: #{String.trim(message)}"
          end

        [code] ->
          String.trim(code)

        _ ->
          nil
      end

    if warning do
      {:ok, &Map.update!(&1, :warnings, fn warnings -> [warning | warnings] end)}
    else
      :ignore
    end
  end

  defp parse_probe_line("ERR\t" <> rest) do
    case String.split(rest, "\t", parts: 2) do
      [code, message] ->
        if present_string?(message) do
          {:error, format_probe_error(code, message)}
        else
          {:error, format_probe_error(code, nil)}
        end

      [code] ->
        {:error, format_probe_error(code, nil)}

      _ ->
        {:error, "SSH discovery failed."}
    end
  end

  defp parse_probe_line(_), do: :ignore

  defp empty_inventory do
    Map.new(@inventory_keys, fn key -> {key, []} end)
  end

  defp put_inventory_item(acc, key, item) do
    update_in(acc, [:inventory, key], fn items -> [item | items] end)
  end

  defp normalize_inventory(inventory) do
    inventory
    |> Enum.map(fn {key, items} -> {key, normalize_inventory_items(key, items)} end)
    |> Map.new()
  end

  defp normalize_inventory_items("system_users", items) do
    items
    |> Enum.uniq_by(fn item -> {item.login, item.domain} end)
    |> Enum.sort_by(fn item -> {item.login || "", item.domain || ""} end)
  end

  defp normalize_inventory_items(_key, items) do
    items
    |> Enum.uniq()
    |> Enum.sort_by(&Map.to_list/1)
  end

  defp normalize_count(value) when is_integer(value), do: value

  defp normalize_count(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {count, ""} -> count
      _ -> 0
    end
  end

  defp normalize_count(_), do: 0

  defp format_probe_error(code, message) do
    code = String.trim(code)

    case normalize_blank(message) do
      nil -> "SSH discovery failed: #{code}"
      normalized_message -> "SSH discovery failed: #{code}: #{normalized_message}"
    end
  end

  defp send_channel_input(conn, channel, data) when is_binary(data) do
    case apply(:ssh_connection, :send, [conn, channel, data]) do
      :ok ->
        _ = apply(:ssh_connection, :send_eof, [conn, channel])
        :ok

      other ->
        {:error, "failed to send SSH input: #{inspect(other)}"}
    end
  end

  defp collect_channel_output(conn, channel, acc, exit_status) do
    receive do
      {:ssh_cm, ^conn, {:data, ^channel, _type, data}} ->
        collect_channel_output(conn, channel, acc <> IO.iodata_to_binary(data), exit_status)

      {:ssh_cm, ^conn, {:exit_status, ^channel, status}} ->
        collect_channel_output(conn, channel, acc, status)

      {:ssh_cm, ^conn, {:eof, ^channel}} ->
        collect_channel_output(conn, channel, acc, exit_status)

      {:ssh_cm, ^conn, {:closed, ^channel}} ->
        if is_nil(exit_status) or exit_status == 0 do
          {:ok, acc}
        else
          {:error, "remote command exited with status #{exit_status}: #{acc}"}
        end
    after
      15_000 ->
        {:error, "timed out waiting for SSH command output"}
    end
  end

  defp format_ssh_reason(reason) do
    case reason do
      {:error, nested} -> format_ssh_reason(nested)
      _ -> inspect(reason)
    end
  end

  defp normalize_port(value) when is_integer(value), do: value

  defp normalize_port(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {port, ""} -> port
      _ -> 22
    end
  end

  defp normalize_port(_), do: 22

  defp normalize_blank(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_blank(_), do: nil

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_), do: false

  defp normalize_string(value) when is_binary(value), do: String.trim(value)
  defp normalize_string(_), do: ""

  defp expand_tilde_path("~" <> rest), do: Path.expand("~" <> rest)
  defp expand_tilde_path(path), do: path

  defp shell_single_quote(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
