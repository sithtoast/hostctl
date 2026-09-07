"""Runs only in the disposable Docker image; no host mail folders are mounted."""
import email
import imaplib
import json
import os
from pathlib import Path
import smtplib
import socket
import subprocess
import time


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True, timeout=45).stdout


def write(path, text, mode=0o644):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    path.chmod(mode)


def wait_for(check, description):
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        try:
            result = check()
            if result:
                return result
        except (OSError, imaplib.IMAP4.error):
            pass
        time.sleep(0.1)
    raise AssertionError(f'Timed out: {description}')


def connect(port):
    with socket.create_connection(('127.0.0.1', port), timeout=1):
        return True


def main():
    bundle = json.loads(Path('/bundle.json').read_text())
    for path, content in bundle['files'].items():
        write(path, content, 0o755 if '/bin/' in path else 0o644)
    run('groupadd', '-g', '5000', 'vmail')
    run('useradd', '-u', '5000', '-g', 'vmail', '-d', '/var/mail/vhosts', 'vmail')
    for name in ('a', 'b', 'c'):
        Path(f'/var/mail/vhosts/example.com/{name}').mkdir(parents=True)
    run('chown', '-R', 'vmail:vmail', '/var/mail/vhosts')
    write('/etc/dovecot/passwd', ''.join(f'{name}@example.com:{{PLAIN}}test-password:5000:5000::/var/mail/vhosts/example.com/{name}::\n' for name in ('a', 'b', 'c')))
    write('/etc/dovecot/conf.d/99-hostctl.conf', '''
mail_location = maildir:~/Maildir
ssl = no
disable_plaintext_auth = no
log_path = /tmp/dovecot.log
mail_debug = yes
passdb {
 driver = passwd-file
 args = /etc/dovecot/passwd
}
userdb {
 driver = passwd-file
 args = /etc/dovecot/passwd
}
''')
    auth = Path('/etc/dovecot/conf.d/10-auth.conf')
    auth.write_text(auth.read_text().replace('!include auth-system.conf.ext', '# system auth disabled in test'))
    write('/etc/postfix/virtual_domains', 'example.com OK\n')
    write('/etc/postfix/virtual_mailbox', ''.join(f'{name}@example.com example.com/{name}/Maildir/\n' for name in ('a', 'b', 'c')))
    for name in ('virtual_domains', 'virtual_mailbox'):
        run('postmap', f'/etc/postfix/{name}')
    for key, value in {
        'myhostname': 'mail.example.com', 'mydestination': 'localhost',
        'inet_interfaces': 'loopback-only', 'inet_protocols': 'ipv4',
        'virtual_mailbox_domains': 'hash:/etc/postfix/virtual_domains',
        'virtual_mailbox_maps': 'hash:/etc/postfix/virtual_mailbox',
        'virtual_mailbox_base': '/var/mail/vhosts', 'virtual_uid_maps': 'static:5000',
        'virtual_gid_maps': 'static:5000', 'virtual_minimum_uid': '5000',
        'virtual_transport': 'lmtp:unix:private/hostctl-lmtp',
        'smtpd_milters': 'inet:127.0.0.1:11332', 'non_smtpd_milters': 'inet:127.0.0.1:11332',
        'milter_default_action': 'accept', 'milter_protocol': '6',
    }.items():
        run('postconf', '-e', f'{key}={value}')
    # A test-only symbol gives one synthetic message a deterministic high
    # score without depending on remote blocklists or GTUBE's forced action.
    write('/etc/rspamd/rspamd.local.lua', """
rspamd_config:register_symbol({
  name = 'HOSTCTL_TEST_SPAM', score = 12.0,
  callback = function(task)
    return task:get_header('X-Hostctl-Test-Spam') == 'yes'
  end
})
""")
    print(run('rspamadm', 'configtest'), flush=True)
    run('doveconf', '-n')
    for path in Path('/etc/dovecot/hostctl-spam').glob('*.sieve'):
        run('sievec', str(path))
    run('postfix', 'check')
    print('PASS: Rspamd, Dovecot, Sieve and Postfix configuration validation', flush=True)
    Path('/run/rspamd').mkdir(exist_ok=True)
    for directory in ('/run/hostctl-spam-redis', '/var/lib/hostctl-spam-redis'):
        Path(directory).mkdir(mode=0o700)
        run('chown', '_rspamd:_rspamd', directory)
    run('runuser', '-u', '_rspamd', '--', 'redis-server', '/etc/hostctl-spam-redis.conf', '--daemonize', 'yes')
    logs = open('/tmp/daemons.log', 'w')
    subprocess.Popen(['rspamd', '-f', '-u', '_rspamd', '-g', '_rspamd'], stdout=logs, stderr=logs)
    subprocess.run(['dovecot'], stdout=logs, stderr=logs, check=True, timeout=15)
    subprocess.run(['postfix', 'start'], stdout=logs, stderr=logs, check=True, timeout=15)
    for port in (25, 143, 11332):
        wait_for(lambda port=port: connect(port), f'port {port}')
    controller = Path('/run/rspamd/hostctl-controller.sock')
    wait_for(controller.exists, 'private learning controller')
    assert controller.stat().st_mode & 0o777 == 0o600
    assert controller.stat().st_uid == 5000
    assert Path('/run/hostctl-spam-redis/redis.sock').stat().st_mode & 0o777 == 0o600
    # Test the actual sieve program with controlled headers for all recipients.
    # sieve-test executes Pigeonhole without delivering or changing a mailbox.
    script = '/etc/dovecot/hostctl-spam/delivery.sieve'
    for recipient, score, sender, expected in [
        ('a@example.com', 4, 'normal@example.org', 'Junk'),
        ('b@example.com', 4, 'normal@example.org', 'INBOX'),
        ('c@example.com', 6, 'normal@example.org', 'Junk'),
        ('a@example.com', 20, 'friend@example.org', 'INBOX'),
        ('a@example.com', 0, 'bad@example.org', 'Junk'),
    ]:
        write('/tmp/message.eml', f'From: {sender}\nTo: {recipient}\nSubject: sieve test\nX-Hostctl-Spam-Level: {"*" * score}\n\nTest body\n')
        output = run('sieve-test', '-u', recipient, '-r', recipient, '-f', sender, script, '/tmp/message.eml')
        assert f'store message in folder: {expected}' in output, output
    print('PASS: recipient-specific thresholds, inherited defaults, allowed and blocked senders', flush=True)
    # Real SMTP -> Rspamd -> LMTP -> Maildir delivery, including a forged header.
    with smtplib.SMTP('127.0.0.1', 25, timeout=30) as smtp:
        smtp.sendmail('friend@example.org', ['a@example.com', 'b@example.com'],
                      'From: friend@example.org\r\nTo: a@example.com,b@example.com\r\nSubject: mail delivery\r\nMessage-ID: <integration@example.org>\r\nX-Hostctl-Spam-Level: ********************\r\n\r\nHello team, tomorrow we will review the deployment schedule, customer feedback, monitoring alerts, database backups, project budgets, documentation, release checklist, software testing, support requests, and holiday coverage. Please bring questions and share your progress during the meeting.\r\n')
    clients = []
    for name in ('a', 'b'):
        client = imaplib.IMAP4('127.0.0.1')
        client.login(f'{name}@example.com', 'test-password')
        clients.append(client)
        def find_message():
            client.select('INBOX')
            return client.search(None, 'ALL')[1][0]
        ids = wait_for(find_message, f'LMTP delivery for {name}')
        raw = client.fetch(ids.split()[-1], '(RFC822)')[1][0][1]
        message = email.message_from_bytes(raw)
        assert message.get_all('X-Hostctl-Spam-Level') != ['********************'], message
        assert len(message.get_all('X-Hostctl-Spam-Level', [])) <= 1, message
    print('PASS: SMTP scanning, forged-score replacement, LMTP delivery to two recipients', flush=True)
    client = clients[0]
    client.create('Junk')
    rspamd_log = Path('/var/log/rspamd/rspamd.log')
    spam_before = rspamd_log.read_text().count('learned message as spam: integration@example.org')
    assert client.copy('1', 'Junk')[0] == 'OK'
    client.select('Junk')
    wait_for(lambda: client.search(None, 'ALL')[1][0], 'Junk copy')
    wait_for(lambda: rspamd_log.read_text().count('learned message as spam: integration@example.org') > spam_before,
             'Rspamd confirms spam learning')
    # Rspamd may correctly deduplicate a correction back to the original
    # auto-learned ham class. Also use a fresh, unscanned message to prove a
    # new ham example is learned by the Inbox hook itself.
    assert client.copy('1', 'INBOX')[0] == 'OK'
    wait_for(lambda: any(text in rspamd_log.read_text() for text in (
        'learned message as ham: integration@example.org',
        '<integration@example.org> has been already learned as ham')),
        'Rspamd accepts correction back to ham')
    fresh_ham = b"From: colleague@example.org\r\nTo: a@example.com\r\nMessage-ID: <fresh-ham@example.org>\r\nSubject: design review\r\n\r\nThank you for preparing the product design review. We discussed typography, navigation, accessibility, keyboard interactions, search functionality, performance, customer interviews, research findings, prototype testing, documentation improvements, and our upcoming launch schedule.\r\n"
    assert client.append('Junk', None, None, fresh_ham)[0] == 'OK'
    client.select('Junk')
    fresh_id = client.search(None, 'ALL')[1][0].split()[-1]
    assert client.copy(fresh_id, 'INBOX')[0] == 'OK'
    wait_for(lambda: 'learned message as ham: fresh-ham@example.org' in rspamd_log.read_text(),
             'Rspamd confirms learning a fresh ham example')
    print('PASS: IMAP Junk and Inbox corrections train Rspamd', flush=True)
    with smtplib.SMTP('127.0.0.1', 25, timeout=30) as smtp:
        smtp.sendmail('spam@example.org', ['a@example.com', 'b@example.com'],
                      'From: spam@example.org\r\nTo: a@example.com,b@example.com\r\nSubject: synthetic high score\r\nMessage-ID: <high-score@example.org>\r\nX-Hostctl-Test-Spam: yes\r\n\r\nSynthetic spam filtering integration test.\r\n')
    for client in clients:
        def find_spam():
            client.select('Junk')
            return client.search(None, 'HEADER', 'Message-ID', 'high-score@example.org')[1][0]
        spam_id = wait_for(find_spam, 'high-score message goes to Junk')
        raw = client.fetch(spam_id, '(RFC822)')[1][0][1]
        message = email.message_from_bytes(raw)
        assert 'Spam score reached mailbox threshold' in message['X-Hostctl-Junk-Reason'], message
        assert len(message['X-Hostctl-Spam-Level'].strip()) >= 8, message
        client.logout()
    print('PASS: high-score SMTP mail is accepted and sorted into Junk for both recipients', flush=True)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        if isinstance(error, subprocess.CalledProcessError):
            print(error.stdout, error.stderr, flush=True)
        for path in ['/tmp/daemons.log', '/tmp/dovecot.log', '/var/log/rspamd/rspamd.log']:
            if Path(path).exists():
                print('\n'.join(line for line in Path(path).read_text().splitlines() if 'uploaded redis script' not in line and any(word in line.lower() for word in ['learn', 'sieve', 'error', 'fatal', 'failed']))[-14000:], flush=True)
        print(run('postqueue', '-p'), flush=True)
        raise
