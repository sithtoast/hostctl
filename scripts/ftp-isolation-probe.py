#!/usr/bin/env python3
"""Loopback-only FTP/HTTP checks. Credentials come from a private local state file."""
import ftplib
import io
import json
import os
import ssl
import sys
import urllib.request


FTP_PORT = 21
HTTP_PORT = 80

def check(ok, message):
    if not ok:
        raise RuntimeError(message)
    print("PASS: " + message, flush=True)


def connect(owner):
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    # This tests local FTP behavior, not certificate issuance or public TLS trust.
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    ftp = ftplib.FTP_TLS(context=context, timeout=10)
    ftp.connect("127.0.0.1", FTP_PORT)
    try:
        ftp.auth()
    except ftplib.error_perm as error:
        if str(error)[:3] not in ("500", "502", "504", "530"):
            ftp.close()
            raise
        ftp.close()
        ftp = ftplib.FTP(timeout=10)
        ftp.connect("127.0.0.1", FTP_PORT)
    try:
        ftp.login(owner["login"], owner["password"])
        if isinstance(ftp, ftplib.FTP_TLS):
            ftp.prot_p()
        return ftp
    except BaseException:
        ftp.close()
        raise


def retrieve(ftp, path):
    data = io.BytesIO()
    ftp.retrbinary("RETR " + path, data.write)
    return data.getvalue()


def denied(operation, message):
    try:
        operation()
    except ftplib.error_perm as error:
        check(str(error)[:3] in ("550", "553"), message + " (file access denied)")
    else:
        raise RuntimeError(message + ": unexpectedly permitted")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def http(owner, path, token):
    request = urllib.request.Request(f"http://127.0.0.1:{HTTP_PORT}/" + path,
                                    headers={"Host": owner["domain"], "X-Hostctl-Test": token})
    # Ignore environment proxies; all test traffic must stay on loopback.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    with opener.open(request, timeout=10) as response:
        return response.read()


def run(state, mode):
    owners = state["owners"]
    if mode == "prepare":
        # Seed both targets before checking either cross-account boundary.
        for owner in owners:
            ftp = connect(owner)
            try:
                marker = (state["tag"] + ":" + owner["login"]).encode()
                ftp.storbinary("STOR boot-proof.txt", io.BytesIO(marker))
            finally:
                ftp.close()
    for owner, peer in [(owners[0], owners[1]), (owners[1], owners[0])]:
        ftp = connect(owner)
        try:
            label = owner["domain"]
            marker = (state["tag"] + ":" + owner["login"]).encode()
            check(retrieve(ftp, "boot-proof.txt") == marker, label + ": retained FTP marker")
            check(os.stat(owner["root"] + "/boot-proof.txt").st_uid == owner["uid"],
                  label + ": FTP upload has the expected Linux owner")
            check(http(owner, "boot-proof.txt", state["token"]) == marker, label + ": uploaded file served by Nginx")
            identity = json.loads(http(owner, "ftp-probe.php", state["token"]))
            check(identity["uid"] == owner["uid"] and identity["proof"] == marker.decode(),
                  label + ": dedicated PHP reads retained FTP content")

            ftp.storbinary("STOR operations.txt", io.BytesIO(b"first"))
            ftp.storbinary("STOR operations.txt", io.BytesIO(b"replacement"))
            ftp.rename("operations.txt", "renamed.txt")
            check(retrieve(ftp, "renamed.txt") == b"replacement", label + ": upload, overwrite and rename")
            ftp.delete("renamed.txt")
            denied(lambda: retrieve(ftp, "renamed.txt"), label + ": deleted file unavailable")
            ftp.mkd("probe-directory")
            ftp.rmd("probe-directory")
            ftp.cwd("../../../../")
            check(ftp.pwd() == "/", label + ": FTP remains chrooted")
            denied(lambda: retrieve(ftp, peer["root"] + "/boot-proof.txt"), label + ": cross-owner read denied")
            denied(lambda: ftp.storbinary("STOR " + peer["root"] + "/cross-write.txt", io.BytesIO(b"FAIL")),
                   label + ": cross-owner write denied")
            denied(lambda: retrieve(ftp, "peer-link.txt"), label + ": cross-owner symlink read denied")
            denied(lambda: ftp.storbinary("STOR peer-link.txt", io.BytesIO(b"FAIL")),
                   label + ": cross-owner symlink write denied")
            # Confirm a denied request did not simply break the connection.
            check(retrieve(ftp, "boot-proof.txt") == marker, label + ": own FTP access still works")
        finally:
            ftp.close()
    for owner in owners:
        marker = (state["tag"] + ":" + owner["login"]).encode()
        check(http(owner, "boot-proof.txt", state["token"]) == marker,
              owner["domain"] + ": peer attempts left content unchanged")


if __name__ == "__main__":
    try:
        with open(sys.argv[1]) as source:
            state = json.load(source)
        check(sys.argv[2] in ("prepare", "verify"), "valid probe phase")
        run(state, sys.argv[2])
    except Exception as error:
        # Avoid printing state, credentials, or FTP debug transcripts.
        print("FAIL: " + str(error), file=sys.stderr)
        sys.exit(1)
