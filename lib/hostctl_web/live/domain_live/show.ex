defmodule HostctlWeb.DomainLive.Show do
  use HostctlWeb, :live_view

  require Logger

  @ssl_log_poll_ms 1000

  alias Hostctl.Hosting
  alias Hostctl.Hosting.{SslCertificate, Subdomain, DomainS3Backend}
  alias Hostctl.Accounts.Scope
  alias Hostctl.Settings
  alias Hostctl.WebServer
  alias Hostctl.MailServer

  def mount(%{"id" => id} = params, _session, socket) do
    scope = socket.assigns.current_scope
    is_admin = scope.user.role == "admin"

    domain =
      if is_admin do
        Hosting.get_domain_for_admin!(id)
      else
        Hosting.get_domain!(scope, id)
      end

    domain_scope =
      if is_admin && domain.user_id != scope.user.id do
        Scope.for_user(domain.user)
      else
        scope
      end

    subdomains = Hosting.list_subdomains(domain)
    ssl_cert = Hosting.get_ssl_certificate(domain)
    cron_jobs = Hosting.list_cron_jobs(domain)
    # If an active cert exists but ssl_enabled is still false (e.g. cert was
    # provisioned before the auto-enable logic was added), fix it now.
    domain =
      if ssl_cert && ssl_cert.status == "active" && !domain.ssl_enabled do
        case Hosting.update_domain(domain_scope, domain, %{ssl_enabled: true}) do
          {:ok, updated} -> updated
          _ -> domain
        end
      else
        domain
      end

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Hostctl.PubSub, "domain:#{domain.id}:ssl")
    end

    # Pre-populate log lines from any previously persisted log
    existing_log_lines =
      if ssl_cert && ssl_cert.log do
        ssl_cert.log
        |> String.split("\n")
        |> Enum.with_index()
        |> Enum.map(fn {line, idx} -> %{id: idx, text: line} end)
      else
        []
      end

    section = section_from_param(params["section"])

    {:ok,
     socket
     |> stream(:ssl_log_lines, existing_log_lines)
     |> assign(:page_title, domain.name)
     |> assign(:active_tab, :domains)
     |> assign(:domain_scope, domain_scope)
     |> assign(:domain, domain)
     |> assign(:ssl_cert, ssl_cert)
     |> assign(:active_section, section)
     |> stream(:subdomains, subdomains)
     |> assign(:subdomain_names, Enum.map(subdomains, & &1.name))
     |> stream(:cron_jobs, cron_jobs)
     |> assign_ssl_form()
     |> assign_subdomain_form()
     |> assign_cron_form()
     |> assign_smarthost_form()
     |> assign_s3_backends()
     |> assign(:s3_editing, nil)
     |> assign(:s3_form, nil)
     |> assign(:mg_key, "")
     |> assign(:mg_region, "us")
     |> assign(:mg_status, nil)
     |> assign(
       :bandwidth_chart_data,
       bandwidth_chart_data(Hosting.list_bandwidth_snapshots(domain))
     )
     |> maybe_schedule_ssl_log_poll(ssl_cert)}
  end

  def handle_params(params, _url, socket) do
    section = section_from_param(params["section"])

    {:noreply, refresh_section_streams(socket, section)}
  end

  def handle_info({:ssl_cert_updated, cert}, socket) do
    # Reload domain too so ssl_enabled toggle reflects any auto-update
    domain = Hosting.get_domain!(socket.assigns.domain_scope, cert.domain_id)

    log_lines =
      if cert.log do
        cert.log
        |> String.split("\n")
        |> Enum.with_index()
        |> Enum.map(fn {line, idx} -> %{id: idx, text: line} end)
      else
        []
      end

    {:noreply,
     socket
     |> assign(:ssl_cert, cert)
     |> assign(:domain, domain)
     |> assign(:ssl_log_counter, length(log_lines))
     |> stream(:ssl_log_lines, log_lines, reset: true)
     |> maybe_schedule_ssl_log_poll(cert)}
  end

  def handle_info({:ssl_log, line}, socket) do
    idx = socket.assigns[:ssl_log_counter] || 0
    entry = %{id: idx, text: normalize_ssl_log_line(line)}

    {:noreply,
     socket
     |> assign(:ssl_log_counter, idx + 1)
     |> stream_insert(:ssl_log_lines, entry)}
  end

  def handle_info(:refresh_ssl_log, socket) do
    cert = Hosting.get_ssl_certificate(socket.assigns.domain)

    log_lines =
      if cert && cert.log do
        cert.log
        |> String.split("\n")
        |> Enum.with_index()
        |> Enum.map(fn {line, idx} -> %{id: idx, text: normalize_ssl_log_line(line)} end)
      else
        []
      end

    {:noreply,
     socket
     |> assign(:ssl_cert, cert)
     |> assign(:ssl_log_counter, length(log_lines))
     |> stream(:ssl_log_lines, log_lines, reset: true)
     |> maybe_schedule_ssl_log_poll(cert)}
  end

  def handle_info(message, socket) do
    Logger.debug("[DomainLive.Show] Ignoring unexpected message: #{inspect(message)}")
    {:noreply, socket}
  end

  def handle_event("set_section", %{"section" => section}, socket) do
    domain = socket.assigns.domain
    section = section_from_param(section)

    {:noreply,
     push_patch(socket,
       to: ~p"/domains/#{domain.id}?section=#{Atom.to_string(section)}"
     )}
  end

  def handle_event("sync_nginx", _params, socket) do
    case WebServer.sync_domain(socket.assigns.domain) do
      :ok ->
        {:noreply, put_flash(socket, :info, "Nginx config rebuilt and reloaded.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Nginx sync failed: #{inspect(reason)}")}
    end
  end

  def handle_event("toggle_ssl", _params, socket) do
    domain = socket.assigns.domain

    case Hosting.update_domain(socket.assigns.domain_scope, domain, %{
           ssl_enabled: !domain.ssl_enabled
         }) do
      {:ok, updated} ->
        {:noreply, socket |> assign(:domain, updated) |> put_flash(:info, "SSL setting updated.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not update SSL setting.")}
    end
  end

  def handle_event("toggle_allow_http_with_ssl", _params, socket) do
    domain = socket.assigns.domain

    case Hosting.update_domain(socket.assigns.domain_scope, domain, %{
           allow_http_with_ssl: !domain.allow_http_with_ssl
         }) do
      {:ok, updated} ->
        message =
          if updated.allow_http_with_ssl do
            "HTTP will remain available alongside HTTPS."
          else
            "HTTP will now redirect to HTTPS when SSL is active."
          end

        {:noreply, socket |> assign(:domain, updated) |> put_flash(:info, message)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not update HTTP/HTTPS behavior.")}
    end
  end

  def handle_event("cancel_ssl", _params, socket) do
    case Hosting.delete_ssl_certificate(socket.assigns.ssl_cert) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:ssl_cert, nil)
         |> stream(:ssl_log_lines, [], reset: true)
         |> put_flash(:info, "SSL certificate request cancelled.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not cancel SSL request.")}
    end
  end

  def handle_event("request_ssl", %{"ssl_certificate" => params} = request_params, socket) do
    try do
      domain = socket.assigns.domain
      email = params["email"]
      allow_http_with_ssl = truthy_param?(request_params["allow_http_with_ssl"])
      covers_wildcard_subdomains = truthy_param?(params["covers_wildcard_subdomains"])
      replacing_existing_cert? = socket.assigns.ssl_cert != nil

      Logger.info(
        "[SSLTRACE2] request_ssl received domain_id=#{domain.id} domain=#{domain.name} " <>
          "replace_existing=#{replacing_existing_cert?} wildcard=#{covers_wildcard_subdomains} " <>
          "allow_http_with_ssl=#{allow_http_with_ssl}"
      )

      submitted_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

      request_scope_line =
        if covers_wildcard_subdomains do
          "Requested scope: #{domain.name}, *.#{domain.name}"
        else
          "Requested scope: #{domain.name}"
        end

      initial_log_lines = [
        %{id: 0, text: "Request accepted at #{submitted_at}"},
        %{id: 1, text: request_scope_line},
        %{id: 2, text: "Preparing SSL provisioning task..."}
      ]

      if covers_wildcard_subdomains and !Settings.cloudflare_enabled?() do
        Logger.warning(
          "[SSLTRACE2] request_ssl blocked domain_id=#{domain.id} reason=wildcard_without_cloudflare"
        )

        {:noreply,
         socket
         |> assign(:ssl_log_counter, 1)
         |> stream(
           :ssl_log_lines,
           [
             %{
               id: 0,
               text:
                 "ERROR: Wildcard SSL requires Cloudflare DNS challenge setup first. Configure DNS Provider in panel settings, then retry."
             }
           ],
           reset: true
         )
         |> put_flash(
           :error,
           "Wildcard SSL requires Cloudflare DNS challenge setup first. Configure DNS Provider in panel settings, then retry."
         )}
      else
        Logger.info(
          "[SSLTRACE2] request_ssl step=update_domain_no_sync start domain_id=#{domain.id}"
        )

        case Hosting.update_domain_no_sync(socket.assigns.domain_scope, domain, %{
               allow_http_with_ssl: allow_http_with_ssl
             }) do
          {:ok, updated_domain} ->
            Logger.info(
              "[SSLTRACE2] request_ssl step=update_domain_no_sync ok domain_id=#{updated_domain.id}"
            )

            Logger.info(
              "[SSLTRACE2] request_ssl step=create_ssl_certificate start domain_id=#{updated_domain.id}"
            )

            case Hosting.create_ssl_certificate(
                   updated_domain,
                   %{
                     cert_type: "lets_encrypt",
                     status: "pending",
                     email: email,
                     covers_wildcard_subdomains: covers_wildcard_subdomains
                   },
                   replace_existing: replacing_existing_cert?
                 ) do
              {:ok, cert} ->
                Logger.info(
                  "[SSLTRACE2] request_ssl accepted domain_id=#{updated_domain.id} cert_id=#{cert.id} status=#{cert.status}"
                )

                message =
                  if replacing_existing_cert? do
                    "SSL certificate reissue initiated for #{updated_domain.name}."
                  else
                    "SSL certificate request initiated for #{updated_domain.name}."
                  end

                {:noreply,
                 socket
                 |> assign(:domain, updated_domain)
                 |> assign(:ssl_cert, cert)
                 |> assign(:ssl_log_counter, length(initial_log_lines))
                 |> stream(:ssl_log_lines, initial_log_lines, reset: true)
                 |> put_flash(:info, message)}

              {:error, reason} ->
                Logger.error(
                  "[SSLTRACE2] request_ssl step=create_ssl_certificate failed domain_id=#{updated_domain.id} reason=#{inspect(reason)}"
                )

                {:noreply,
                 socket
                 |> assign(:ssl_log_counter, 1)
                 |> stream(
                   :ssl_log_lines,
                   [%{id: 0, text: "ERROR: Could not initiate SSL request."}],
                   reset: true
                 )
                 |> put_flash(:error, "Could not initiate SSL request.")}
            end

          {:error, reason} ->
            Logger.error(
              "[SSLTRACE2] request_ssl step=update_domain_no_sync failed domain_id=#{domain.id} reason=#{inspect(reason)}"
            )

            {:noreply,
             socket
             |> assign(:ssl_log_counter, 1)
             |> stream(
               :ssl_log_lines,
               [%{id: 0, text: "ERROR: Could not initiate SSL request."}],
               reset: true
             )
             |> put_flash(:error, "Could not initiate SSL request.")}
        end
      end
    rescue
      e ->
        Logger.error(
          "[SSLTRACE2] request_ssl crashed domain_id=#{socket.assigns.domain.id} error=#{Exception.message(e)}"
        )

        {:noreply,
         socket
         |> assign(:ssl_log_counter, 1)
         |> stream(
           :ssl_log_lines,
           [%{id: 0, text: "ERROR: SSL request crashed before provisioning started."}],
           reset: true
         )
         |> put_flash(:error, "Could not initiate SSL request.")}
    catch
      kind, reason ->
        Logger.error(
          "[SSLTRACE2] request_ssl caught kind=#{inspect(kind)} domain_id=#{socket.assigns.domain.id} reason=#{inspect(reason)}"
        )

        {:noreply,
         socket
         |> assign(:ssl_log_counter, 1)
         |> stream(
           :ssl_log_lines,
           [%{id: 0, text: "ERROR: SSL request crashed before provisioning started."}],
           reset: true
         )
         |> put_flash(:error, "Could not initiate SSL request.")}
    end
  end

  def handle_event("request_ssl", params, socket) do
    Logger.error(
      "[SSLTRACE2] request_ssl invalid_payload domain_id=#{socket.assigns.domain.id} payload=#{inspect(params)}"
    )

    {:noreply,
     socket
     |> assign(:ssl_log_counter, 1)
     |> stream(
       :ssl_log_lines,
       [%{id: 0, text: "ERROR: SSL request payload was invalid."}],
       reset: true
     )
     |> put_flash(:error, "Could not initiate SSL request due to invalid input.")}
  end

  # Subdomain events
  def handle_event("validate_subdomain", %{"subdomain" => params}, socket) do
    params = Map.put(params, "domain_name", socket.assigns.domain.name)

    form =
      %Subdomain{}
      |> Hosting.change_subdomain(params)
      |> to_form(action: :validate)

    {:noreply, assign(socket, :subdomain_form, form)}
  end

  def handle_event("save_subdomain", %{"subdomain" => params}, socket) do
    params = Map.put(params, "domain_name", socket.assigns.domain.name)

    case Hosting.create_subdomain(socket.assigns.domain, params) do
      {:ok, subdomain} ->
        {:noreply,
         socket
         |> stream_insert(:subdomains, subdomain)
         |> assign_subdomain_form()
         |> assign(:subdomain_names, [subdomain.name | socket.assigns.subdomain_names])
         |> put_flash(:info, "Subdomain #{subdomain.name}.#{socket.assigns.domain.name} created.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :subdomain_form, to_form(changeset))}
    end
  end

  def handle_event("toggle_autoindex", _params, socket) do
    domain = socket.assigns.domain

    case Hosting.update_domain(socket.assigns.domain_scope, domain, %{
           autoindex: !domain.autoindex
         }) do
      {:ok, updated} ->
        {:noreply,
         socket |> assign(:domain, updated) |> put_flash(:info, "Directory listings updated.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not update directory listings.")}
    end
  end

  def handle_event("toggle_subdomain_autoindex", %{"id" => id}, socket) do
    subdomains = Hosting.list_subdomains(socket.assigns.domain)
    sub = Enum.find(subdomains, &(to_string(&1.id) == id))

    if sub do
      case Hosting.update_subdomain(sub, %{autoindex: !sub.autoindex}) do
        {:ok, updated} ->
          {:noreply,
           socket
           |> stream_insert(:subdomains, updated)
           |> put_flash(:info, "Directory listings updated.")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Could not update directory listings.")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("delete_subdomain", %{"id" => id}, socket) do
    subdomains = Hosting.list_subdomains(socket.assigns.domain)
    subdomain = Enum.find(subdomains, &(to_string(&1.id) == id))

    if subdomain do
      {:ok, _} = Hosting.delete_subdomain(subdomain)

      {:noreply,
       socket
       |> stream_delete(:subdomains, subdomain)
       |> assign(:subdomain_names, List.delete(socket.assigns.subdomain_names, subdomain.name))}
    else
      {:noreply, socket}
    end
  end

  # Cron job events
  def handle_event("validate_cron", %{"cron_job" => params}, socket) do
    form =
      socket.assigns.domain
      |> Ecto.build_assoc(:cron_jobs)
      |> Hosting.change_cron_job(params)
      |> to_form(action: :validate)

    {:noreply, assign(socket, :cron_form, form)}
  end

  def handle_event("save_cron", %{"cron_job" => params}, socket) do
    case Hosting.create_cron_job(socket.assigns.domain, params) do
      {:ok, cron_job} ->
        {:noreply,
         socket
         |> stream_insert(:cron_jobs, cron_job)
         |> assign_cron_form()
         |> put_flash(:info, "Cron job created.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :cron_form, to_form(changeset))}
    end
  end

  def handle_event("delete_cron", %{"id" => id}, socket) do
    cron_jobs = Hosting.list_cron_jobs(socket.assigns.domain)
    cron_job = Enum.find(cron_jobs, &(to_string(&1.id) == id))

    if cron_job do
      {:ok, _} = Hosting.delete_cron_job(cron_job)
      {:noreply, stream_delete(socket, :cron_jobs, cron_job)}
    else
      {:noreply, socket}
    end
  end

  # Smarthost events
  def handle_event("validate_smarthost", %{"smarthost" => params}, socket) do
    changeset =
      Hosting.change_domain_smarthost_setting(socket.assigns.smarthost_setting, params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :smarthost_form, to_form(changeset, as: :smarthost))}
  end

  def handle_event("submit_smarthost", %{"action" => "apply"} = params, socket) do
    domain = socket.assigns.domain
    smarthost_params = Map.get(params, "smarthost", %{})

    case Hosting.save_domain_smarthost_setting(domain, smarthost_params) do
      {:ok, setting} ->
        apply_status =
          if Settings.feature_enabled?("email") do
            case MailServer.apply_domain_smarthost(setting) do
              :ok -> :applied
              {:error, _reason} -> :apply_failed
            end
          else
            :saved
          end

        socket =
          socket
          |> assign(:smarthost_setting, setting)
          |> assign(
            :smarthost_form,
            to_form(Hosting.change_domain_smarthost_setting(setting), as: :smarthost)
          )
          |> assign(:smarthost_apply_status, apply_status)

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, :smarthost_form, to_form(changeset, as: :smarthost))}
    end
  end

  def handle_event("submit_smarthost", %{"smarthost" => params}, socket) do
    domain = socket.assigns.domain

    case Hosting.save_domain_smarthost_setting(domain, params) do
      {:ok, setting} ->
        socket =
          socket
          |> assign(:smarthost_setting, setting)
          |> assign(
            :smarthost_form,
            to_form(Hosting.change_domain_smarthost_setting(setting), as: :smarthost)
          )
          |> assign(:smarthost_apply_status, :saved)

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, :smarthost_form, to_form(changeset, as: :smarthost))}
    end
  end

  def handle_event("toggle_smarthost_password", _params, socket) do
    {:noreply, update(socket, :smarthost_show_password, &(!&1))}
  end

  def handle_event(
        "configure_mailgun_smarthost",
        %{"mg_key" => api_key, "mg_region" => region},
        socket
      ) do
    domain_name = socket.assigns.domain.name
    region_atom = if region == "eu", do: :eu, else: :us

    case Hosting.provision_mailgun_for_domain(domain_name, api_key, region_atom) do
      {:ok, %{login: login, password: password}} ->
        smtp_host =
          if region_atom == :eu, do: "[smtp.eu.mailgun.org]", else: "[smtp.mailgun.org]"

        prefilled = %{
          "enabled" => "true",
          "host" => smtp_host,
          "port" => "587",
          "auth_required" => "true",
          "username" => login,
          "password" => password
        }

        setting = socket.assigns.smarthost_setting
        changeset = Hosting.change_domain_smarthost_setting(setting, prefilled)

        {:noreply,
         socket
         |> assign(:smarthost_form, to_form(changeset, as: :smarthost))
         |> assign(:mg_key, api_key)
         |> assign(:mg_region, region)
         |> assign(:mg_status, :ok)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:mg_key, api_key)
         |> assign(:mg_region, region)
         |> assign(:mg_status, {:error, reason})}
    end
  end

  # S3 backend events
  def handle_event("start_new_s3_backend", _params, socket) do
    new_form =
      %DomainS3Backend{}
      |> Hosting.change_s3_backend()
      |> to_form(as: :domain_s3_backend)

    {:noreply,
     socket
     |> assign(:s3_editing, nil)
     |> assign(:s3_form, new_form)}
  end

  def handle_event("edit_s3_backend", %{"id" => id}, socket) do
    backend = Hosting.get_s3_backend_by_id!(String.to_integer(id))

    form =
      backend
      |> Hosting.change_s3_backend()
      |> to_form(as: :domain_s3_backend)

    {:noreply,
     socket
     |> assign(:s3_editing, backend)
     |> assign(:s3_form, form)}
  end

  def handle_event("cancel_s3_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:s3_editing, nil)
     |> assign(:s3_form, nil)}
  end

  def handle_event("validate_s3_backend", %{"domain_s3_backend" => params}, socket) do
    backend = socket.assigns.s3_editing || %DomainS3Backend{}

    form =
      backend
      |> Hosting.change_s3_backend(params)
      |> to_form(action: :validate, as: :domain_s3_backend)

    {:noreply, assign(socket, :s3_form, form)}
  end

  def handle_event("save_s3_backend", %{"domain_s3_backend" => params}, socket) do
    domain = socket.assigns.domain
    backend = socket.assigns.s3_editing

    result =
      if backend do
        Hosting.update_s3_backend(backend, params)
      else
        Hosting.create_s3_backend(domain, params)
      end

    case result do
      {:ok, _saved} ->
        {:noreply,
         socket
         |> assign_s3_backends()
         |> assign(:s3_editing, nil)
         |> assign(:s3_form, nil)
         |> put_flash(:info, "S3 backend saved.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :s3_form, to_form(changeset, as: :domain_s3_backend))}
    end
  end

  def handle_event("toggle_s3_backend", %{"id" => id}, socket) do
    backend = Hosting.get_s3_backend_by_id!(String.to_integer(id))

    case Hosting.update_s3_backend(backend, %{enabled: !backend.enabled}) do
      {:ok, _updated} ->
        {:noreply,
         socket
         |> assign_s3_backends()
         |> put_flash(
           :info,
           if(backend.enabled, do: "S3 backend disabled.", else: "S3 backend enabled.")
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not toggle S3 backend.")}
    end
  end

  def handle_event("delete_s3_backend", %{"id" => id}, socket) do
    backend = Hosting.get_s3_backend_by_id!(String.to_integer(id))

    case Hosting.delete_s3_backend(backend) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign_s3_backends()
         |> assign(:s3_editing, nil)
         |> assign(:s3_form, nil)
         |> put_flash(:info, "S3 backend removed.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not remove S3 backend.")}
    end
  end

  defp assign_ssl_form(socket) do
    user_email = socket.assigns.domain_scope.user.email
    existing_cert = socket.assigns[:ssl_cert]

    changeset =
      Hosting.change_ssl_certificate(%SslCertificate{}, %{
        email: (existing_cert && existing_cert.email) || user_email,
        covers_wildcard_subdomains: existing_cert && existing_cert.covers_wildcard_subdomains
      })

    assign(socket, :ssl_form, to_form(changeset, as: :ssl_certificate))
  end

  defp assign_subdomain_form(socket) do
    assign(socket, :subdomain_form, to_form(Hosting.change_subdomain(%Subdomain{})))
  end

  defp assign_cron_form(socket) do
    assign(socket, :cron_form, to_form(Hosting.change_cron_job(%Hostctl.Hosting.CronJob{})))
  end

  defp assign_smarthost_form(socket) do
    setting = Hosting.get_domain_smarthost_setting(socket.assigns.domain)

    socket
    |> assign(:smarthost_setting, setting)
    |> assign(
      :smarthost_form,
      to_form(Hosting.change_domain_smarthost_setting(setting), as: :smarthost)
    )
    |> assign(:smarthost_show_password, false)
    |> assign(:smarthost_apply_status, nil)
  end

  defp assign_s3_backends(socket) do
    backends = Hosting.list_s3_backends(socket.assigns.domain)
    assign(socket, :s3_backends, backends)
  end

  defp truthy_param?(value), do: value in [true, "true", "on", "1"]

  defp normalize_ssl_log_line(line) when is_binary(line), do: String.replace_invalid(line, "?")
  defp normalize_ssl_log_line(line), do: inspect(line)

  defp maybe_schedule_ssl_log_poll(socket, %SslCertificate{status: "pending"}) do
    Process.send_after(self(), :refresh_ssl_log, @ssl_log_poll_ms)
    socket
  end

  defp maybe_schedule_ssl_log_poll(socket, _), do: socket

  defp section_from_param("overview"), do: :overview
  defp section_from_param("subdomains"), do: :subdomains
  defp section_from_param("dns"), do: :dns
  defp section_from_param("ssl"), do: :ssl
  defp section_from_param("cron"), do: :cron
  defp section_from_param("smarthost"), do: :smarthost
  defp section_from_param("s3"), do: :s3
  defp section_from_param(_), do: :overview

  defp refresh_section_streams(socket, section) do
    domain = socket.assigns.domain

    socket =
      case section do
        :subdomains ->
          stream(socket, :subdomains, Hosting.list_subdomains(domain), reset: true)

        :cron ->
          stream(socket, :cron_jobs, Hosting.list_cron_jobs(domain), reset: true)

        _ ->
          socket
      end

    assign(socket, :active_section, section)
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_tab={@active_tab}>
      <div class="space-y-6">
        <%!-- Header --%>
        <div class="flex items-center gap-4">
          <.link
            navigate={~p"/domains"}
            class="text-gray-400 hover:text-gray-600 dark:hover:text-gray-200"
          >
            <.icon name="hero-arrow-left" class="w-5 h-5" />
          </.link>
          <div class="flex-1">
            <div class="flex items-center gap-3">
              <h1 class="text-2xl font-bold text-gray-900 dark:text-white">{@domain.name}</h1>
              <span class={[
                "inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium",
                cond do
                  @domain.status == "active" ->
                    "bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-400"

                  @domain.status == "suspended" ->
                    "bg-red-100 text-red-700 dark:bg-red-900/30 dark:text-red-400"

                  true ->
                    "bg-yellow-100 text-yellow-700 dark:bg-yellow-900/30 dark:text-yellow-400"
                end
              ]}>
                {@domain.status}
              </span>
            </div>
            <p class="mt-0.5 text-sm text-gray-500 dark:text-gray-400">
              PHP {@domain.php_version} &middot; {if @domain.document_root,
                do: @domain.document_root,
                else: "Default root"}
            </p>
          </div>
        </div>

        <%!-- Section tabs --%>
        <div class="flex gap-1 p-1 bg-gray-100 dark:bg-gray-800 rounded-lg w-fit">
          <% tabs = [
            {"Overview", :overview, "hero-home"},
            {"Subdomains", :subdomains, "hero-link"},
            {"DNS", :dns, "hero-server"},
            {"SSL", :ssl, "hero-lock-closed"},
            {"Cron Jobs", :cron, "hero-clock"}
          ]

          tabs =
            if Settings.feature_enabled?("email") do
              tabs ++ [{"Smarthost", :smarthost, "hero-envelope-open"}]
            else
              tabs
            end

          tabs = tabs ++ [{"S3 Storage", :s3, "hero-cloud-arrow-up"}] %>
          <%= for {label, section, icon} <- tabs do %>
            <button
              phx-click="set_section"
              phx-value-section={section}
              class={[
                "flex items-center gap-1.5 px-3 py-1.5 rounded-md text-sm font-medium transition-colors",
                if(@active_section == section,
                  do: "bg-white dark:bg-gray-700 text-gray-900 dark:text-white shadow-sm",
                  else: "text-gray-600 dark:text-gray-400 hover:text-gray-900 dark:hover:text-white"
                )
              ]}
            >
              <.icon name={icon} class="w-3.5 h-3.5" />
              {label}
            </button>
          <% end %>
        </div>

        <%!-- Overview --%>
        <%= if @active_section == :overview do %>
          <div class="grid grid-cols-1 gap-4 sm:grid-cols-3">
            <.info_card
              label="Document Root"
              value={@domain.document_root || "Not set"}
              icon="hero-folder"
            />
            <.info_card
              label="PHP Version"
              value={"PHP #{@domain.php_version}"}
              icon="hero-code-bracket"
            />
            <.info_card
              label="SSL Certificate"
              value={
                cond do
                  @ssl_cert && @ssl_cert.status == "active" -> "Active"
                  @ssl_cert && @ssl_cert.status == "pending" -> "Issuing…"
                  @ssl_cert && @ssl_cert.status == "expired" -> "Expired"
                  true -> "None"
                end
              }
              icon="hero-lock-closed"
            />
          </div>

          <%!-- Resource Usage --%>
          <div class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800 p-6">
            <h3 class="text-base font-semibold text-gray-900 dark:text-white mb-4">Resource Usage</h3>
            <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
              <div class="flex items-center gap-4 p-4 rounded-lg bg-indigo-50 dark:bg-indigo-950/30 border border-indigo-100 dark:border-indigo-900/50">
                <div class="flex items-center justify-center w-10 h-10 rounded-lg bg-indigo-100 dark:bg-indigo-900/50 shrink-0">
                  <.icon
                    name="hero-circle-stack"
                    class="w-5 h-5 text-indigo-600 dark:text-indigo-400"
                  />
                </div>
                <div>
                  <p class="text-xs text-indigo-600 dark:text-indigo-400 font-medium uppercase tracking-wide">
                    Disk Usage
                  </p>
                  <p class="text-2xl font-bold text-indigo-700 dark:text-indigo-300 leading-tight">
                    {format_mb(@domain.disk_usage_mb)}
                  </p>
                </div>
              </div>
              <div class="flex items-center gap-4 p-4 rounded-lg bg-emerald-50 dark:bg-emerald-950/30 border border-emerald-100 dark:border-emerald-900/50">
                <div class="flex items-center justify-center w-10 h-10 rounded-lg bg-emerald-100 dark:bg-emerald-900/50 shrink-0">
                  <.icon
                    name="hero-arrow-up-tray"
                    class="w-5 h-5 text-emerald-600 dark:text-emerald-400"
                  />
                </div>
                <div>
                  <p class="text-xs text-emerald-600 dark:text-emerald-400 font-medium uppercase tracking-wide">
                    Bandwidth Used
                  </p>
                  <p class="text-2xl font-bold text-emerald-700 dark:text-emerald-300 leading-tight">
                    {format_mb(@domain.bandwidth_used_mb)}
                  </p>
                  <p class="text-xs text-emerald-500 dark:text-emerald-400 mt-0.5">this month</p>
                </div>
              </div>
            </div>

            <%!-- Bandwidth history chart --%>
            <%= if @bandwidth_chart_data != [] do %>
              <div class="mt-6">
                <p class="text-xs font-medium text-gray-500 dark:text-gray-400 mb-3">
                  Bandwidth — last 6 months
                </p>
                <% max_mb =
                  Enum.max_by(@bandwidth_chart_data, & &1.mb_used, fn -> %{mb_used: 1} end).mb_used %>
                <% max_mb = max(max_mb, 1) %>
                <div class="flex items-end gap-2 h-24">
                  <%= for bar <- @bandwidth_chart_data do %>
                    <% pct = round(bar.mb_used / max_mb * 100) %>
                    <div class="flex-1 flex flex-col items-center gap-1">
                      <span class="text-xs text-gray-500 dark:text-gray-400">
                        <%= if bar.mb_used > 0 do %>
                          {format_mb(bar.mb_used)}
                        <% end %>
                      </span>
                      <div
                        class="w-full bg-gray-100 dark:bg-gray-800 rounded-t relative"
                        style="height: 56px"
                      >
                        <div
                          class={[
                            "absolute bottom-0 left-0 right-0 rounded-t transition-all duration-500",
                            if(bar.current?,
                              do: "bg-emerald-500",
                              else: "bg-emerald-300 dark:bg-emerald-700"
                            )
                          ]}
                          style={"height: #{pct}%"}
                        >
                        </div>
                      </div>
                      <span class="text-xs text-gray-400 dark:text-gray-500 whitespace-nowrap">
                        {bar.label}
                      </span>
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>
          </div>

          <div class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800 p-6">
            <h3 class="text-base font-semibold text-gray-900 dark:text-white mb-4">Quick Actions</h3>
            <div class="grid grid-cols-2 gap-3 sm:grid-cols-4">
              <button
                phx-click="set_section"
                phx-value-section="dns"
                class="flex flex-col items-center gap-2 p-4 rounded-lg border border-gray-200 dark:border-gray-700 hover:border-indigo-300 dark:hover:border-indigo-700 hover:bg-indigo-50 dark:hover:bg-indigo-950/30 transition-colors"
              >
                <.icon name="hero-server" class="w-5 h-5 text-gray-500 dark:text-gray-400" />
                <span class="text-xs font-medium text-gray-700 dark:text-gray-300">Manage DNS</span>
              </button>
              <.link
                navigate={~p"/email"}
                class="flex flex-col items-center gap-2 p-4 rounded-lg border border-gray-200 dark:border-gray-700 hover:border-indigo-300 dark:hover:border-indigo-700 hover:bg-indigo-50 dark:hover:bg-indigo-950/30 transition-colors"
              >
                <.icon name="hero-envelope" class="w-5 h-5 text-gray-500 dark:text-gray-400" />
                <span class="text-xs font-medium text-gray-700 dark:text-gray-300">
                  Email Accounts
                </span>
              </.link>
              <.link
                navigate={~p"/databases"}
                class="flex flex-col items-center gap-2 p-4 rounded-lg border border-gray-200 dark:border-gray-700 hover:border-indigo-300 dark:hover:border-indigo-700 hover:bg-indigo-50 dark:hover:bg-indigo-950/30 transition-colors"
              >
                <.icon name="hero-circle-stack" class="w-5 h-5 text-gray-500 dark:text-gray-400" />
                <span class="text-xs font-medium text-gray-700 dark:text-gray-300">Databases</span>
              </.link>
              <button
                phx-click="set_section"
                phx-value-section="ssl"
                class="flex flex-col items-center gap-2 p-4 rounded-lg border border-gray-200 dark:border-gray-700 hover:border-indigo-300 dark:hover:border-indigo-700 hover:bg-indigo-50 dark:hover:bg-indigo-950/30 transition-colors"
              >
                <.icon name="hero-lock-closed" class="w-5 h-5 text-gray-500 dark:text-gray-400" />
                <span class="text-xs font-medium text-gray-700 dark:text-gray-300">
                  SSL Certificate
                </span>
              </button>
              <button
                phx-click="sync_nginx"
                class="flex flex-col items-center gap-2 p-4 rounded-lg border border-gray-200 dark:border-gray-700 hover:border-orange-300 dark:hover:border-orange-700 hover:bg-orange-50 dark:hover:bg-orange-950/30 transition-colors"
              >
                <.icon name="hero-arrow-path" class="w-5 h-5 text-gray-500 dark:text-gray-400" />
                <span class="text-xs font-medium text-gray-700 dark:text-gray-300">
                  Rebuild Config
                </span>
              </button>
            </div>
          </div>
        <% end %>

        <%!-- Subdomains --%>
        <%= if @active_section == :subdomains do %>
          <div class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800">
            <div class="px-6 py-4 border-b border-gray-200 dark:border-gray-800 flex items-center justify-between">
              <h3 class="text-base font-semibold text-gray-900 dark:text-white">Subdomains</h3>
              <button
                phx-click="toggle_autoindex"
                class={[
                  "flex items-center gap-2 px-3 py-1.5 rounded-lg text-xs font-medium border transition-colors",
                  if(@domain.autoindex,
                    do:
                      "bg-indigo-50 dark:bg-indigo-950/40 border-indigo-200 dark:border-indigo-800 text-indigo-700 dark:text-indigo-300",
                    else:
                      "bg-gray-50 dark:bg-gray-800 border-gray-200 dark:border-gray-700 text-gray-600 dark:text-gray-400 hover:border-indigo-300"
                  )
                ]}
              >
                <.icon
                  name={if @domain.autoindex, do: "hero-folder-open", else: "hero-folder"}
                  class="w-3.5 h-3.5"
                />
                {if @domain.autoindex, do: "Dir listings on", else: "Dir listings off"} ({@domain.name})
              </button>
            </div>
            <div class="p-6 border-b border-gray-200 dark:border-gray-800">
              <.form
                for={@subdomain_form}
                id="subdomain-form"
                phx-change="validate_subdomain"
                phx-submit="save_subdomain"
                class="flex gap-3"
              >
                <div class="flex-1">
                  <.input
                    field={@subdomain_form[:name]}
                    type="text"
                    placeholder="www"
                    label="Subdomain name"
                  />
                </div>
                <div class="flex-1">
                  <.input
                    field={@subdomain_form[:document_root]}
                    type="text"
                    placeholder="/var/www/sub.example.com/public"
                    label="Document root (optional)"
                  />
                </div>
                <div class="flex items-end pb-0.5">
                  <button
                    type="submit"
                    class="px-4 py-2 bg-indigo-600 hover:bg-indigo-700 text-white text-sm font-medium rounded-lg transition-colors whitespace-nowrap"
                  >
                    Add Subdomain
                  </button>
                </div>
              </.form>
            </div>
            <div
              id="subdomains"
              phx-update="stream"
              class="divide-y divide-gray-100 dark:divide-gray-800"
            >
              <div class="hidden only:flex items-center justify-center py-10 text-sm text-gray-400">
                No subdomains yet.
              </div>
              <div
                :for={{id, sub} <- @streams.subdomains}
                id={id}
                class="flex items-center justify-between px-6 py-3"
              >
                <div>
                  <p class="text-sm font-medium text-gray-900 dark:text-white">
                    {sub.name}.{@domain.name}
                  </p>
                  <p class="text-xs text-gray-500">{sub.document_root || "Default"}</p>
                </div>
                <div class="flex items-center gap-3">
                  <button
                    phx-click="toggle_subdomain_autoindex"
                    phx-value-id={sub.id}
                    class={[
                      "flex items-center gap-1.5 px-2.5 py-1 rounded-md text-xs font-medium border transition-colors",
                      if(sub.autoindex,
                        do:
                          "bg-indigo-50 dark:bg-indigo-950/40 border-indigo-200 dark:border-indigo-800 text-indigo-700 dark:text-indigo-300",
                        else:
                          "bg-gray-50 dark:bg-gray-800 border-gray-200 dark:border-gray-700 text-gray-500 dark:text-gray-400 hover:border-indigo-300"
                      )
                    ]}
                    title="Toggle directory listings"
                  >
                    <.icon
                      name={if sub.autoindex, do: "hero-folder-open", else: "hero-folder"}
                      class="w-3 h-3"
                    />
                    {if sub.autoindex, do: "Listings on", else: "Listings off"}
                  </button>
                  <button
                    phx-click="delete_subdomain"
                    phx-value-id={sub.id}
                    data-confirm="Delete this subdomain?"
                    class="text-xs text-red-500 hover:text-red-600"
                  >
                    Delete
                  </button>
                </div>
              </div>
            </div>
          </div>
        <% end %>

        <%!-- DNS --%>
        <%= if @active_section == :dns do %>
          <.link
            navigate={~p"/domains/#{@domain.id}/dns"}
            class="inline-flex items-center gap-2 px-4 py-2 bg-indigo-600 hover:bg-indigo-700 text-white text-sm font-medium rounded-lg transition-colors"
          >
            <.icon name="hero-arrow-right" class="w-4 h-4" /> Open DNS Manager
          </.link>
        <% end %>

        <%!-- SSL --%>
        <%= if @active_section == :ssl do %>
          <div class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800 p-6">
            <h3 class="text-base font-semibold text-gray-900 dark:text-white mb-4">
              SSL Certificate
            </h3>
            <%= if @ssl_cert do %>
              <div class="space-y-4">
                <div class="flex items-center gap-3">
                  <div class={[
                    "flex items-center justify-center w-10 h-10 rounded-lg",
                    cond do
                      @ssl_cert.status == "active" -> "bg-green-100 dark:bg-green-900/30"
                      @ssl_cert.status == "expired" -> "bg-red-100 dark:bg-red-900/30"
                      true -> "bg-yellow-100 dark:bg-yellow-900/30"
                    end
                  ]}>
                    <%= cond do %>
                      <% @ssl_cert.status == "active" -> %>
                        <.icon
                          name="hero-lock-closed"
                          class="w-5 h-5 text-green-600 dark:text-green-400"
                        />
                      <% @ssl_cert.status == "expired" -> %>
                        <.icon
                          name="hero-exclamation-triangle"
                          class="w-5 h-5 text-red-600 dark:text-red-400"
                        />
                      <% true -> %>
                        <.icon
                          name="hero-arrow-path"
                          class="w-5 h-5 text-yellow-600 dark:text-yellow-400 animate-spin"
                        />
                    <% end %>
                  </div>
                  <div>
                    <p class="text-sm font-medium text-gray-900 dark:text-white capitalize">
                      {@ssl_cert.cert_type} certificate
                    </p>
                    <p class={[
                      "text-xs capitalize",
                      cond do
                        @ssl_cert.status == "active" -> "text-green-600 dark:text-green-400"
                        @ssl_cert.status == "expired" -> "text-red-600 dark:text-red-400"
                        true -> "text-yellow-600 dark:text-yellow-400"
                      end
                    ]}>
                      {@ssl_cert.status}
                      <%= if @ssl_cert.status == "pending" do %>
                        – issuing certificate, this may take a minute…
                      <% end %>
                    </p>
                    <%= if @ssl_cert.covers_wildcard_subdomains do %>
                      <p class="text-xs text-indigo-600 dark:text-indigo-400 mt-1">
                        Wildcard coverage enabled for subdomains of {@domain.name}
                      </p>
                    <% end %>
                  </div>
                  <%= if @ssl_cert.status == "pending" do %>
                    <button
                      id="cancel-ssl-btn"
                      phx-click="cancel_ssl"
                      data-confirm="Cancel this SSL request and remove the pending certificate?"
                      class="ml-auto text-xs text-red-500 hover:text-red-600 transition-colors"
                    >
                      Cancel
                    </button>
                  <% end %>
                </div>

                <div class="rounded-lg border border-gray-200 dark:border-gray-800 p-4">
                  <h4 class="text-sm font-medium text-gray-900 dark:text-white">
                    Current certificate details
                  </h4>
                  <dl class="mt-3 space-y-2 text-sm">
                    <div class="flex flex-wrap items-start gap-2">
                      <dt class="text-gray-500 dark:text-gray-400 w-24">Protects</dt>
                      <dd class="text-gray-900 dark:text-white font-mono text-xs break-all">
                        <%= if @ssl_cert.covers_wildcard_subdomains do %>
                          {@domain.name}, *.{@domain.name}
                        <% else %>
                          {@domain.name}
                        <% end %>
                      </dd>
                    </div>
                    <div class="flex flex-wrap items-start gap-2">
                      <dt class="text-gray-500 dark:text-gray-400 w-24">Expires</dt>
                      <dd class="text-gray-900 dark:text-white">
                        <%= cond do %>
                          <% @ssl_cert.expires_at -> %>
                            {Calendar.strftime(@ssl_cert.expires_at, "%B %d, %Y")}
                          <% @ssl_cert.status == "pending" -> %>
                            Pending issuance
                          <% true -> %>
                            Not available
                        <% end %>
                      </dd>
                    </div>
                  </dl>
                </div>

                <%= if @ssl_cert.status != "pending" do %>
                  <div class="rounded-lg border border-gray-200 dark:border-gray-800 p-4">
                    <p class="text-sm font-medium text-gray-900 dark:text-white">
                      Reissue or replace certificate
                    </p>
                    <p class="mt-1 text-sm text-gray-500 dark:text-gray-400">
                      Request a fresh Let's Encrypt certificate, including wildcard coverage for all subdomains if needed.
                    </p>
                    <.form
                      for={@ssl_form}
                      id="ssl-reissue-form"
                      phx-submit="request_ssl"
                      class="mt-4 flex w-full max-w-xl flex-col gap-3"
                    >
                      <.input
                        field={@ssl_form[:email]}
                        type="email"
                        placeholder="you@example.com"
                        label="Let's Encrypt email"
                        class="w-full px-3 py-2 text-sm border border-gray-300 dark:border-gray-700 rounded-lg bg-white dark:bg-gray-800 text-gray-900 dark:text-white focus:outline-none focus:ring-2 focus:ring-indigo-500"
                      />
                      <div class="rounded-lg border border-gray-200 dark:border-gray-800 p-4">
                        <input type="hidden" name="allow_http_with_ssl" value="false" />
                        <div class="flex items-start justify-between gap-4">
                          <div>
                            <p class="text-sm font-medium text-gray-900 dark:text-white">
                              Keep HTTP available after SSL is enabled
                            </p>
                            <p class="mt-1 text-xs text-gray-500 dark:text-gray-400">
                              Leave this off to redirect all HTTP traffic to HTTPS once the certificate is active.
                            </p>
                          </div>
                          <label class="relative inline-flex items-center cursor-pointer shrink-0">
                            <input
                              type="checkbox"
                              name="allow_http_with_ssl"
                              value="true"
                              checked={@domain.allow_http_with_ssl}
                              class="sr-only peer"
                            />
                            <div class="w-11 h-6 bg-gray-200 dark:bg-gray-700 peer-focus:outline-none peer-focus:ring-2 peer-focus:ring-indigo-400 rounded-full peer peer-checked:bg-indigo-600 after:content-[''] after:absolute after:top-[2px] after:left-[2px] after:bg-white after:rounded-full after:h-5 after:w-5 after:transition-all peer-checked:after:translate-x-5">
                            </div>
                          </label>
                        </div>
                      </div>
                      <div class="rounded-lg border border-gray-200 dark:border-gray-800 p-4">
                        <input
                          type="hidden"
                          name={@ssl_form[:covers_wildcard_subdomains].name}
                          value="false"
                        />
                        <div class="flex items-start justify-between gap-4">
                          <div>
                            <p class="text-sm font-medium text-gray-900 dark:text-white">
                              Use one wildcard certificate for all subdomains
                            </p>
                            <p class="mt-1 text-xs text-gray-500 dark:text-gray-400">
                              Requests <strong>{@domain.name}</strong>
                              and <strong>*.{@domain.name}</strong>
                              on the same certificate. This requires DNS-based validation.
                            </p>
                          </div>
                          <label class="relative inline-flex items-center cursor-pointer shrink-0">
                            <input
                              type="checkbox"
                              id={@ssl_form[:covers_wildcard_subdomains].id}
                              name={@ssl_form[:covers_wildcard_subdomains].name}
                              value="true"
                              checked={
                                Phoenix.HTML.Form.normalize_value(
                                  "checkbox",
                                  @ssl_form[:covers_wildcard_subdomains].value
                                )
                              }
                              class="sr-only peer"
                            />
                            <div class="w-11 h-6 bg-gray-200 dark:bg-gray-700 peer-focus:outline-none peer-focus:ring-2 peer-focus:ring-indigo-400 rounded-full peer peer-checked:bg-indigo-600 after:content-[''] after:absolute after:top-[2px] after:left-[2px] after:bg-white after:rounded-full after:h-5 after:w-5 after:transition-all peer-checked:after:translate-x-5">
                            </div>
                          </label>
                        </div>
                      </div>
                      <button
                        type="submit"
                        data-confirm="Replace the current certificate with a newly issued Let's Encrypt certificate request?"
                        class="inline-flex items-center gap-2 px-4 py-2 bg-indigo-600 hover:bg-indigo-700 text-white text-sm font-medium rounded-lg transition-colors"
                      >
                        <.icon name="hero-arrow-path" class="w-4 h-4" /> Reissue Certificate
                      </button>
                    </.form>
                  </div>
                <% end %>

                <%= if @ssl_cert.status == "active" and @domain.ssl_enabled do %>
                  <div class="rounded-lg border border-gray-200 dark:border-gray-800 p-4 flex items-start justify-between gap-4">
                    <div>
                      <p class="text-sm font-medium text-gray-900 dark:text-white">
                        HTTP alongside HTTPS
                      </p>
                      <p class="text-sm text-gray-500 dark:text-gray-400 mt-1">
                        <%= if @domain.allow_http_with_ssl do %>
                          Port 80 stays available and serves the site without redirecting.
                        <% else %>
                          Port 80 redirects all traffic to HTTPS.
                        <% end %>
                      </p>
                    </div>
                    <button
                      id="toggle-ssl-http-btn"
                      phx-click="toggle_allow_http_with_ssl"
                      class={[
                        "shrink-0 inline-flex items-center gap-2 rounded-lg px-3 py-2 text-sm font-medium transition-colors",
                        if(@domain.allow_http_with_ssl,
                          do:
                            "bg-amber-100 text-amber-800 hover:bg-amber-200 dark:bg-amber-900/30 dark:text-amber-300 dark:hover:bg-amber-900/40",
                          else:
                            "bg-emerald-100 text-emerald-800 hover:bg-emerald-200 dark:bg-emerald-900/30 dark:text-emerald-300 dark:hover:bg-emerald-900/40"
                        )
                      ]}
                    >
                      <%= if @domain.allow_http_with_ssl do %>
                        <.icon name="hero-arrow-uturn-left" class="w-4 h-4" /> Redirect HTTP
                      <% else %>
                        <.icon name="hero-globe-alt" class="w-4 h-4" /> Allow HTTP
                      <% end %>
                    </button>
                  </div>
                <% end %>

                <div>
                  <p class="text-xs font-medium text-gray-500 dark:text-gray-400 mb-1.5 uppercase tracking-wide">
                    Certbot output
                  </p>
                  <div
                    id="ssl-log"
                    phx-update="stream"
                    phx-hook=".SslLogScroll"
                    class="bg-gray-950 rounded-lg p-4 font-mono text-xs text-green-400 overflow-y-auto max-h-72 space-y-0.5"
                  >
                    <div id="ssl-log-empty" class="hidden only:block text-gray-600">
                      Waiting for output…
                    </div>
                    <div
                      :for={{id, entry} <- @streams.ssl_log_lines}
                      id={id}
                      class="whitespace-pre-wrap break-all leading-5"
                    >
                      {entry.text}
                    </div>
                  </div>
                  <script :type={Phoenix.LiveView.ColocatedHook} name=".SslLogScroll">
                    export default {
                      updated() { this.el.scrollTop = this.el.scrollHeight }
                    }
                  </script>
                </div>
              </div>
            <% else %>
              <div class="text-center py-6">
                <.icon
                  name="hero-lock-open"
                  class="w-10 h-10 text-gray-300 dark:text-gray-600 mx-auto mb-3"
                />
                <p class="text-sm font-medium text-gray-900 dark:text-white">No SSL certificate</p>
                <p class="text-sm text-gray-500 dark:text-gray-400 mb-4">
                  Secure your domain with a free Let's Encrypt certificate
                </p>
                <.form
                  for={@ssl_form}
                  id="ssl-request-form"
                  phx-submit="request_ssl"
                  class="mx-auto flex w-full max-w-xl flex-col gap-3"
                >
                  <.input
                    field={@ssl_form[:email]}
                    type="email"
                    placeholder="you@example.com"
                    label="Let's Encrypt email"
                    class="w-full px-3 py-2 text-sm border border-gray-300 dark:border-gray-700 rounded-lg bg-white dark:bg-gray-800 text-gray-900 dark:text-white focus:outline-none focus:ring-2 focus:ring-indigo-500"
                  />
                  <div class="rounded-lg border border-gray-200 dark:border-gray-800 p-4 text-left">
                    <input type="hidden" name="allow_http_with_ssl" value="false" />
                    <div class="flex items-start justify-between gap-4">
                      <div>
                        <p class="text-sm font-medium text-gray-900 dark:text-white">
                          Keep HTTP available after SSL is enabled
                        </p>
                        <p class="mt-1 text-xs text-gray-500 dark:text-gray-400">
                          Leave this off to redirect all HTTP traffic to HTTPS once the certificate is active.
                        </p>
                      </div>
                      <label class="relative inline-flex items-center cursor-pointer shrink-0">
                        <input
                          type="checkbox"
                          name="allow_http_with_ssl"
                          value="true"
                          checked={@domain.allow_http_with_ssl}
                          class="sr-only peer"
                        />
                        <div class="w-11 h-6 bg-gray-200 dark:bg-gray-700 peer-focus:outline-none peer-focus:ring-2 peer-focus:ring-indigo-400 rounded-full peer peer-checked:bg-indigo-600 after:content-[''] after:absolute after:top-[2px] after:left-[2px] after:bg-white after:rounded-full after:h-5 after:w-5 after:transition-all peer-checked:after:translate-x-5">
                        </div>
                      </label>
                    </div>
                  </div>
                  <div class="rounded-lg border border-gray-200 dark:border-gray-800 p-4 text-left">
                    <input
                      type="hidden"
                      name={@ssl_form[:covers_wildcard_subdomains].name}
                      value="false"
                    />
                    <div class="flex items-start justify-between gap-4">
                      <div>
                        <p class="text-sm font-medium text-gray-900 dark:text-white">
                          Use one wildcard certificate for all subdomains
                        </p>
                        <p class="mt-1 text-xs text-gray-500 dark:text-gray-400">
                          Requests <strong>{@domain.name}</strong>
                          and <strong>*.{@domain.name}</strong>
                          on the same certificate. This requires DNS-based validation.
                        </p>
                      </div>
                      <label class="relative inline-flex items-center cursor-pointer shrink-0">
                        <input
                          type="checkbox"
                          id={@ssl_form[:covers_wildcard_subdomains].id}
                          name={@ssl_form[:covers_wildcard_subdomains].name}
                          value="true"
                          checked={
                            Phoenix.HTML.Form.normalize_value(
                              "checkbox",
                              @ssl_form[:covers_wildcard_subdomains].value
                            )
                          }
                          class="sr-only peer"
                        />
                        <div class="w-11 h-6 bg-gray-200 dark:bg-gray-700 peer-focus:outline-none peer-focus:ring-2 peer-focus:ring-indigo-400 rounded-full peer peer-checked:bg-indigo-600 after:content-[''] after:absolute after:top-[2px] after:left-[2px] after:bg-white after:rounded-full after:h-5 after:w-5 after:transition-all peer-checked:after:translate-x-5">
                        </div>
                      </label>
                    </div>
                  </div>
                  <button
                    type="submit"
                    class="inline-flex items-center gap-2 px-4 py-2 bg-green-600 hover:bg-green-700 text-white text-sm font-medium rounded-lg transition-colors self-center"
                  >
                    <.icon name="hero-lock-closed" class="w-4 h-4" /> Request Free SSL
                  </button>
                </.form>
              </div>
            <% end %>
          </div>
        <% end %>

        <%!-- Cron Jobs --%>
        <%= if @active_section == :cron do %>
          <div class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800">
            <div class="px-6 py-4 border-b border-gray-200 dark:border-gray-800">
              <h3 class="text-base font-semibold text-gray-900 dark:text-white">Cron Jobs</h3>
            </div>
            <div class="p-6 border-b border-gray-200 dark:border-gray-800">
              <.form
                for={@cron_form}
                id="cron-form"
                phx-change="validate_cron"
                phx-submit="save_cron"
                class="grid grid-cols-1 gap-3 sm:grid-cols-3"
              >
                <.input
                  field={@cron_form[:schedule]}
                  type="text"
                  placeholder="* * * * *"
                  label="Schedule (cron)"
                />
                <div class="sm:col-span-2">
                  <.input
                    field={@cron_form[:command]}
                    type="text"
                    placeholder="/usr/bin/php /var/www/artisan schedule:run"
                    label="Command"
                  />
                </div>
                <div class="sm:col-span-3 flex justify-end">
                  <button
                    type="submit"
                    class="px-4 py-2 bg-indigo-600 hover:bg-indigo-700 text-white text-sm font-medium rounded-lg transition-colors"
                  >
                    Add Cron Job
                  </button>
                </div>
              </.form>
            </div>
            <div
              id="cron-jobs"
              phx-update="stream"
              class="divide-y divide-gray-100 dark:divide-gray-800"
            >
              <div class="hidden only:flex items-center justify-center py-10 text-sm text-gray-400">
                No cron jobs yet.
              </div>
              <div
                :for={{id, job} <- @streams.cron_jobs}
                id={id}
                class="flex items-center justify-between px-6 py-3"
              >
                <div class="flex items-center gap-4">
                  <span class="font-mono text-xs px-2 py-1 bg-gray-100 dark:bg-gray-800 rounded text-gray-600 dark:text-gray-300">
                    {job.schedule}
                  </span>
                  <p class="text-sm text-gray-900 dark:text-white font-mono">{job.command}</p>
                </div>
                <button
                  phx-click="delete_cron"
                  phx-value-id={job.id}
                  data-confirm="Delete this cron job?"
                  class="text-xs text-red-500 hover:text-red-600"
                >
                  Delete
                </button>
              </div>
            </div>
          </div>
        <% end %>

        <%!-- Smarthost --%>
        <%= if @active_section == :smarthost do %>
          <div class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800">
            <div class="px-6 py-5 border-b border-gray-200 dark:border-gray-800">
              <h3 class="text-base font-semibold text-gray-900 dark:text-white">Domain Smarthost</h3>
              <p class="mt-1 text-sm text-gray-500 dark:text-gray-400">
                Override the server-wide relay for outgoing mail from {@domain.name}.
              </p>
            </div>
            <div class="p-6">
              <%!-- Mailgun quick setup --%>
              <div class="mb-6 rounded-lg border border-purple-200 dark:border-purple-800 bg-purple-50 dark:bg-purple-950/20 p-4">
                <div class="flex items-center gap-2 mb-2">
                  <.icon name="hero-bolt" class="w-4 h-4 text-purple-600 dark:text-purple-400" />
                  <span class="text-sm font-semibold text-purple-900 dark:text-purple-200">
                    Quick setup with Mailgun
                  </span>
                </div>
                <p class="text-xs text-purple-700 dark:text-purple-400 mb-3">
                  Enter your Mailgun Private API key to automatically create SMTP credentials
                  for <strong>{@domain.name}</strong> and pre-fill the form below.
                </p>
                <form
                  id="mg-domain-setup-form"
                  phx-submit="configure_mailgun_smarthost"
                  class="flex flex-wrap gap-2"
                >
                  <input
                    type="password"
                    name="mg_key"
                    placeholder="Mailgun Private API key (key-...)"
                    autocomplete="off"
                    class="flex-1 min-w-0 px-3 py-2 text-sm bg-white dark:bg-gray-800 border border-purple-200 dark:border-purple-700 rounded-lg focus:ring-1 focus:ring-purple-400 focus:outline-none text-gray-900 dark:text-white placeholder-gray-400"
                  />
                  <select
                    name="mg_region"
                    class="px-3 py-2 text-sm bg-white dark:bg-gray-800 border border-purple-200 dark:border-purple-700 rounded-lg focus:ring-1 focus:ring-purple-400 focus:outline-none text-gray-900 dark:text-white"
                  >
                    <option value="us" selected>US region</option>
                    <option value="eu">EU region</option>
                  </select>
                  <button
                    type="submit"
                    id="mg-domain-connect-btn"
                    class="px-4 py-2 text-sm font-medium text-white bg-purple-600 hover:bg-purple-700 rounded-lg transition-colors whitespace-nowrap"
                  >
                    Connect
                  </button>
                </form>
                <%= if @mg_status do %>
                  <%= case @mg_status do %>
                    <% :loading -> %>
                      <p class="mt-2 text-xs text-purple-700 dark:text-purple-400 flex items-center gap-1">
                        <.icon name="hero-arrow-path" class="w-3.5 h-3.5 animate-spin" />
                        Connecting to Mailgun and creating SMTP credentials...
                      </p>
                    <% {:ok, _} -> %>
                      <p class="mt-2 text-xs text-green-700 dark:text-green-400 flex items-center gap-1">
                        <.icon name="hero-check-circle" class="w-3.5 h-3.5 shrink-0" />
                        Credentials created and form pre-filled — review and save below.
                      </p>
                    <% {:error, reason} -> %>
                      <p class="mt-2 text-xs text-red-600 dark:text-red-400 flex items-center gap-1">
                        <.icon name="hero-x-circle" class="w-3.5 h-3.5 shrink-0" />
                        {reason}
                      </p>
                  <% end %>
                <% end %>
              </div>

              <.form
                for={@smarthost_form}
                id="smarthost-form"
                phx-change="validate_smarthost"
                phx-submit="submit_smarthost"
                class="space-y-5"
              >
                <%!-- Enable toggle --%>
                <div class="flex items-center gap-3">
                  <.input
                    field={@smarthost_form[:enabled]}
                    type="checkbox"
                    label="Enable domain smarthost"
                  />
                </div>

                <div class={[
                  @smarthost_form[:enabled].value != true && "opacity-50 pointer-events-none"
                ]}>
                  <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
                    <.input
                      field={@smarthost_form[:host]}
                      type="text"
                      label="Relay host"
                      placeholder="smtp.mailgun.org"
                    />
                    <.input
                      field={@smarthost_form[:port]}
                      type="number"
                      label="Port"
                      placeholder="587"
                    />
                  </div>

                  <div class="mt-4 flex items-center gap-3">
                    <.input
                      field={@smarthost_form[:auth_required]}
                      type="checkbox"
                      label="Authentication required"
                    />
                  </div>

                  <div class={[
                    "mt-4 grid grid-cols-1 gap-4 sm:grid-cols-2",
                    @smarthost_form[:auth_required].value != true && "opacity-50 pointer-events-none"
                  ]}>
                    <.input
                      field={@smarthost_form[:username]}
                      type="text"
                      label="Username"
                      placeholder="postmaster@mg.example.com"
                    />
                    <div class="relative">
                      <.input
                        field={@smarthost_form[:password]}
                        type={if(@smarthost_show_password, do: "text", else: "password")}
                        label="Password / API key"
                        placeholder="••••••••"
                      />
                      <button
                        type="button"
                        phx-click="toggle_smarthost_password"
                        class="absolute right-3 top-8 text-gray-400 hover:text-gray-600 dark:hover:text-gray-300"
                      >
                        <.icon
                          name={if(@smarthost_show_password, do: "hero-eye-slash", else: "hero-eye")}
                          class="w-4 h-4"
                        />
                      </button>
                    </div>
                  </div>
                </div>

                <div class="flex items-center justify-between pt-2">
                  <div class="text-sm">
                    <%= cond do %>
                      <% @smarthost_apply_status == :applied -> %>
                        <span class="text-green-600 dark:text-green-400 flex items-center gap-1">
                          <.icon name="hero-check-circle" class="w-4 h-4" /> Saved &amp; applied
                        </span>
                      <% @smarthost_apply_status == :saved -> %>
                        <span class="text-blue-600 dark:text-blue-400 flex items-center gap-1">
                          <.icon name="hero-check" class="w-4 h-4" /> Saved
                        </span>
                      <% @smarthost_apply_status == :apply_failed -> %>
                        <span class="text-red-600 dark:text-red-400 flex items-center gap-1">
                          <.icon name="hero-x-circle" class="w-4 h-4" /> Saved, but apply failed
                        </span>
                      <% true -> %>
                        <span></span>
                    <% end %>
                  </div>
                  <div class="flex gap-2">
                    <button
                      type="submit"
                      name="action"
                      value="save"
                      class="px-4 py-2 text-sm font-medium text-gray-700 dark:text-gray-300 bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg hover:bg-gray-50 dark:hover:bg-gray-700 transition-colors"
                    >
                      Save
                    </button>
                    <button
                      type="submit"
                      name="action"
                      value="apply"
                      class="px-4 py-2 text-sm font-medium text-white bg-indigo-600 hover:bg-indigo-700 rounded-lg transition-colors"
                    >
                      Save &amp; Apply
                    </button>
                  </div>
                </div>
              </.form>
            </div>
          </div>
        <% end %>

        <%!-- S3 Storage --%>
        <%= if @active_section == :s3 do %>
          <div class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800">
            <div class="px-6 py-4 border-b border-gray-200 dark:border-gray-800 flex items-center justify-between">
              <div>
                <h3 class="text-base font-semibold text-gray-900 dark:text-white">
                  S3 Storage Backends
                </h3>
                <p class="text-sm text-gray-500 dark:text-gray-400 mt-0.5">
                  Transparently proxy requests to S3-compatible storage — for the whole domain, a specific subdomain, or a URL path.
                </p>
              </div>
              <button
                type="button"
                phx-click="start_new_s3_backend"
                class="flex items-center gap-1.5 px-3 py-1.5 bg-indigo-600 hover:bg-indigo-700 text-white text-sm font-medium rounded-lg transition-colors"
              >
                <.icon name="hero-plus" class="w-4 h-4" /> Add Backend
              </button>
            </div>

            <div class="divide-y divide-gray-100 dark:divide-gray-800">
              <%!-- Existing backends list --%>
              <%= if @s3_backends == [] && @s3_form == nil do %>
                <div class="px-6 py-10 text-center text-sm text-gray-500 dark:text-gray-400">
                  No S3 backends configured. Click <strong>Add Backend</strong> to get started.
                </div>
              <% end %>

              <%= for backend <- @s3_backends do %>
                <div class="px-6 py-4">
                  <div class="flex items-start justify-between gap-4">
                    <div class="flex items-start gap-3 min-w-0">
                      <%!-- Scope icon + label --%>
                      <div class="flex-shrink-0 mt-0.5">
                        <%= cond do %>
                          <% backend.subdomain != "" && backend.url_path != "" -> %>
                            <.icon name="hero-globe-alt" class="w-5 h-5 text-violet-500" />
                          <% backend.subdomain != "" -> %>
                            <.icon name="hero-globe-alt" class="w-5 h-5 text-blue-500" />
                          <% backend.url_path != "" -> %>
                            <.icon name="hero-folder-open" class="w-5 h-5 text-amber-500" />
                          <% true -> %>
                            <.icon name="hero-server" class="w-5 h-5 text-indigo-500" />
                        <% end %>
                      </div>
                      <div class="min-w-0">
                        <div class="flex items-center gap-2 flex-wrap">
                          <span class="text-sm font-medium text-gray-900 dark:text-white">
                            <%= cond do %>
                              <% backend.subdomain != "" && backend.url_path != "" -> %>
                                {backend.subdomain}.{@domain.name}{backend.url_path}
                              <% backend.subdomain != "" -> %>
                                {backend.subdomain}.{@domain.name}
                              <% backend.url_path != "" -> %>
                                {@domain.name}{backend.url_path}
                              <% true -> %>
                                {@domain.name} (entire domain)
                            <% end %>
                          </span>
                          <span class={[
                            "inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium",
                            if(backend.enabled,
                              do:
                                "bg-emerald-100 text-emerald-700 dark:bg-emerald-950/40 dark:text-emerald-400",
                              else: "bg-gray-100 text-gray-600 dark:bg-gray-800 dark:text-gray-400"
                            )
                          ]}>
                            <span class={[
                              "w-1.5 h-1.5 rounded-full",
                              if(backend.enabled, do: "bg-emerald-500", else: "bg-gray-400")
                            ]}>
                            </span>
                            {if backend.enabled, do: "Active", else: "Disabled"}
                          </span>
                          <%= if backend.access_key_id && backend.access_key_id != "" do %>
                            <span class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium bg-blue-100 text-blue-700 dark:bg-blue-950/40 dark:text-blue-400">
                              <.icon name="hero-lock-closed" class="w-3 h-3" /> Private
                            </span>
                          <% end %>
                        </div>
                        <p class="text-xs text-gray-500 dark:text-gray-400 mt-1 truncate">
                          {backend.endpoint_url}/{backend.bucket}{if backend.path_prefix &&
                                                                       backend.path_prefix != "",
                                                                     do: "/#{backend.path_prefix}",
                                                                     else: ""}
                        </p>
                      </div>
                    </div>

                    <div class="flex items-center gap-2 flex-shrink-0">
                      <button
                        type="button"
                        phx-click="edit_s3_backend"
                        phx-value-id={backend.id}
                        class="px-3 py-1.5 text-xs font-medium text-gray-700 dark:text-gray-300 border border-gray-300 dark:border-gray-700 rounded-lg hover:bg-gray-50 dark:hover:bg-gray-800 transition-colors"
                      >
                        Edit
                      </button>
                      <button
                        type="button"
                        phx-click="toggle_s3_backend"
                        phx-value-id={backend.id}
                        class={[
                          "px-3 py-1.5 text-xs font-medium rounded-lg border transition-colors",
                          if(backend.enabled,
                            do:
                              "border-gray-300 dark:border-gray-700 text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-800",
                            else:
                              "border-emerald-300 dark:border-emerald-700 text-emerald-700 dark:text-emerald-400 hover:bg-emerald-50 dark:hover:bg-emerald-950/30"
                          )
                        ]}
                      >
                        {if backend.enabled, do: "Disable", else: "Enable"}
                      </button>
                      <button
                        type="button"
                        phx-click="delete_s3_backend"
                        phx-value-id={backend.id}
                        data-confirm="Remove this S3 backend?"
                        class="px-3 py-1.5 text-xs font-medium text-red-600 dark:text-red-400 border border-red-200 dark:border-red-900 rounded-lg hover:bg-red-50 dark:hover:bg-red-950/30 transition-colors"
                      >
                        Remove
                      </button>
                    </div>
                  </div>
                </div>
              <% end %>

              <%!-- Add / edit form --%>
              <%= if @s3_form do %>
                <div class="px-6 py-5 bg-gray-50 dark:bg-gray-800/50">
                  <h4 class="text-sm font-semibold text-gray-800 dark:text-gray-100 mb-4">
                    {if @s3_editing, do: "Edit S3 Backend", else: "New S3 Backend"}
                  </h4>
                  <%!-- Datalists for subdomain and url_path suggestions --%>
                  <datalist id="s3-subdomain-list">
                    <option :for={name <- @subdomain_names} value={name} />
                  </datalist>
                  <datalist id="s3-url-path-list">
                    <option value="/assets" />
                    <option value="/static" />
                    <option value="/media" />
                    <option value="/uploads" />
                    <option value="/images" />
                    <option value="/files" />
                  </datalist>
                  <.form
                    for={@s3_form}
                    id="s3-backend-form"
                    phx-change="validate_s3_backend"
                    phx-submit="save_s3_backend"
                    class="space-y-4"
                  >
                    <%!-- Scope --%>
                    <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
                      <.input
                        field={@s3_form[:subdomain]}
                        type="text"
                        label="Subdomain (optional)"
                        placeholder="Leave blank to apply to the entire domain"
                        list="s3-subdomain-list"
                      />
                      <.input
                        field={@s3_form[:url_path]}
                        type="text"
                        label="URL Path (optional)"
                        placeholder="e.g. /assets — leave blank to serve entire domain from S3"
                        list="s3-url-path-list"
                      />
                    </div>
                    <p class="text-xs text-gray-500 dark:text-gray-400 -mt-2">
                      Leave both blank to proxy the whole domain. Fill in <em>Subdomain</em>
                      to apply only to a subdomain. Fill in <em>URL Path</em>
                      to only proxy requests under that path (e.g. <code>/assets</code>).
                    </p>

                    <%!-- S3 settings --%>
                    <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
                      <.input
                        field={@s3_form[:endpoint_url]}
                        type="text"
                        label="Endpoint URL"
                        placeholder="https://s3.amazonaws.com"
                      />
                      <.input
                        field={@s3_form[:bucket]}
                        type="text"
                        label="Bucket Name"
                        placeholder="my-static-site"
                      />
                    </div>
                    <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
                      <.input
                        field={@s3_form[:path_prefix]}
                        type="text"
                        label="Path Prefix (optional)"
                        placeholder="subdirectory/within/bucket"
                      />
                      <.input
                        field={@s3_form[:region]}
                        type="text"
                        label="Region"
                        placeholder="us-east-1"
                      />
                    </div>

                    <%!-- Credentials --%>
                    <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
                      <.input
                        field={@s3_form[:access_key_id]}
                        type="text"
                        label="Access Key ID (optional)"
                        placeholder="Leave blank for public buckets"
                      />
                      <.input
                        field={@s3_form[:secret_access_key]}
                        type="password"
                        label="Secret Access Key (optional)"
                        placeholder={
                          if @s3_editing && @s3_editing.secret_access_key,
                            do: "Stored — enter new value to replace",
                            else: "Leave blank for public buckets"
                        }
                      />
                    </div>

                    <%!-- FTP mount --%>
                    <div class="pt-1 border-t border-gray-200 dark:border-gray-700">
                      <.input
                        field={@s3_form[:ftp_mount_enabled]}
                        type="checkbox"
                        label="Enable transparent FTP access via rclone FUSE mount"
                      />
                      <p class="text-xs text-gray-500 dark:text-gray-400 -mt-1">
                        When enabled, hostctl provisions a systemd service that mounts
                        this S3 bucket at the document root using rclone, allowing FTP
                        users to upload files directly to S3. Requires <code>rclone</code>
                        and <code>user_allow_other</code>
                        in <code>/etc/fuse.conf</code>
                        on the server.
                      </p>
                    </div>

                    <%!-- Directory listing --%>
                    <div class="pt-1 border-t border-gray-200 dark:border-gray-700">
                      <.input
                        field={@s3_form[:directory_listing]}
                        type="checkbox"
                        label="Enable directory listings"
                      />
                      <p class="text-xs text-gray-500 dark:text-gray-400 -mt-1">
                        When enabled, requests to paths ending in <code>/</code>
                        will show an HTML index of files and folders at that S3 prefix.
                        Works for both public and private buckets.
                      </p>
                    </div>

                    <div class="flex items-center gap-3 pt-1">
                      <button
                        type="submit"
                        class="px-4 py-2 bg-indigo-600 hover:bg-indigo-700 text-white text-sm font-medium rounded-lg transition-colors"
                      >
                        {if @s3_editing, do: "Save Changes", else: "Add Backend"}
                      </button>
                      <button
                        type="button"
                        phx-click="cancel_s3_edit"
                        class="px-4 py-2 text-sm font-medium text-gray-600 dark:text-gray-400 hover:text-gray-800 dark:hover:text-gray-200 transition-colors"
                      >
                        Cancel
                      </button>
                    </div>
                  </.form>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  defp format_mb(mb) when is_integer(mb) do
    cond do
      mb >= 1024 -> "#{Float.round(mb / 1024, 2)} GB"
      mb > 0 -> "#{mb} MB"
      true -> "0 MB"
    end
  end

  defp format_mb(_), do: "0 MB"

  # Builds a 6-slot chart dataset (most recent month last).
  # Slots with no snapshot default to 0. The current month is flagged with current?: true.
  defp bandwidth_chart_data(snapshots) do
    today = Date.utc_today()
    snapshot_map = Map.new(snapshots, &{{&1.year, &1.month}, &1.mb_used})

    for offset <- 5..0//-1 do
      total = today.year * 12 + today.month - 1 - offset
      year = div(total, 12)
      month = rem(total, 12) + 1

      %{
        year: year,
        month: month,
        label: "#{month_short(month)} #{rem(year, 100)}",
        mb_used: Map.get(snapshot_map, {year, month}, 0),
        current?: offset == 0
      }
    end
  end

  defp month_short(1), do: "Jan"
  defp month_short(2), do: "Feb"
  defp month_short(3), do: "Mar"
  defp month_short(4), do: "Apr"
  defp month_short(5), do: "May"
  defp month_short(6), do: "Jun"
  defp month_short(7), do: "Jul"
  defp month_short(8), do: "Aug"
  defp month_short(9), do: "Sep"
  defp month_short(10), do: "Oct"
  defp month_short(11), do: "Nov"
  defp month_short(12), do: "Dec"

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :icon, :string, required: true

  defp info_card(assigns) do
    ~H"""
    <div class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800 p-5">
      <div class="flex items-center gap-3">
        <div class="flex items-center justify-center w-9 h-9 rounded-lg bg-gray-100 dark:bg-gray-800 shrink-0">
          <.icon name={@icon} class="w-4 h-4 text-gray-500 dark:text-gray-400" />
        </div>
        <div>
          <p class="text-xs text-gray-500 dark:text-gray-400">{@label}</p>
          <p class="text-sm font-semibold text-gray-900 dark:text-white">{@value}</p>
        </div>
      </div>
    </div>
    """
  end
end
