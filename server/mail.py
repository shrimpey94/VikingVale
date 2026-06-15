"""SMTP outbound mail wrapper for VikingVale.

Configuration is read from process env / a .env file (server/.env, loaded
by server.py via python-dotenv). All the SMTP_* + PUBLIC_BASE_URL keys
are documented in server/.env.example.

The single public API is `send_email(to, subject, body_text, body_html)`.
Returns True on success, False on any failure (caller logs at boundary).
When SMTP isn't configured, returns False with a structured log warning
so callers can gracefully degrade to "email service unavailable, contact
admin" UX.
"""

from __future__ import annotations

import os
import smtplib
import ssl
import time
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from email.utils import formataddr


def _env(key: str, default: str = "") -> str:
    v = os.environ.get(key, default)
    return v.strip() if isinstance(v, str) else default


def is_configured() -> bool:
    """True when all required SMTP envs are set. Cheap precheck so callers
    can show a meaningful UI state instead of failing inside send_email."""
    return bool(_env("SMTP_HOST") and _env("SMTP_USER") and _env("SMTP_PASS")
                and _env("SMTP_FROM_ADDR"))


def public_base_url() -> str:
    """Used to build reset-link URLs that go into outbound emails."""
    return _env("PUBLIC_BASE_URL", "https://example.invalid")


def send_email(to: str, subject: str, body_text: str,
               body_html: str = "") -> bool:
    """Send a plain-text (and optionally HTML alternative) email.

    `to` must be a single recipient address. Returns True on a successful
    SMTP DATA, False otherwise. Failures are logged to stdout — caller is
    not expected to surface SMTP internals to end users.
    """
    if not is_configured():
        print("[mail] SMTP not configured — send_email skipped "
              f"(to={to!r}, subject={subject!r})")
        return False

    host = _env("SMTP_HOST")
    port = int(_env("SMTP_PORT", "587"))
    user = _env("SMTP_USER")
    password = _env("SMTP_PASS")
    from_name = _env("SMTP_FROM_NAME", "VikingVale")
    from_addr = _env("SMTP_FROM_ADDR")

    msg = MIMEMultipart("alternative")
    msg["Subject"] = subject
    msg["From"] = formataddr((from_name, from_addr))
    msg["To"] = to
    # Plain-text part is required by RFC; HTML is optional.
    msg.attach(MIMEText(body_text, "plain", "utf-8"))
    if body_html:
        msg.attach(MIMEText(body_html, "html", "utf-8"))

    try:
        # 587 = STARTTLS, 465 = SMTPS. Default to STARTTLS which is what
        # Gmail's app-password flow and Mailgun's free tier both expect.
        ctx = ssl.create_default_context()
        if port == 465:
            with smtplib.SMTP_SSL(host, port, context=ctx, timeout=15) as s:
                s.login(user, password)
                s.send_message(msg)
        else:
            with smtplib.SMTP(host, port, timeout=15) as s:
                s.ehlo()
                s.starttls(context=ctx)
                s.ehlo()
                s.login(user, password)
                s.send_message(msg)
        print(f"[mail] sent: to={to!r} subject={subject!r}")
        return True
    except Exception as ex:
        # Don't print credentials. Just surface enough to debug at the
        # admin-console level. The full traceback isn't useful here; the
        # exception class name is.
        print(f"[mail] send failed: {type(ex).__name__}: {ex} "
              f"(to={to!r}, host={host}:{port})")
        return False


# ── Templates (very small — server.py builds the bodies and passes them in
# so message text isn't fragmented across files. These constants are just
# the subject lines so they stay consistent across send sites.)

SUBJECT_PASSWORD_RESET = "Reset your VikingVale password"
SUBJECT_PASSWORD_CHANGED = "Your VikingVale password was changed"
SUBJECT_EMAIL_VERIFY = "Verify your VikingVale email"


def build_reset_email(username: str, token: str, expires_minutes: int = 60) -> tuple[str, str]:
    """Returns (text_body, html_body) for a password-reset email.

    Token is what the user pastes into the in-game reset screen. The link
    is informational — VikingVale is a Godot game, so most users will
    type the token, not click a URL. The PUBLIC_BASE_URL link is still
    useful when forwarded to a web inbox.
    """
    link = f"{public_base_url()}/reset?token={token}"
    text = (
        f"Hail {username},\n\n"
        f"A password reset was requested for your VikingVale account. If "
        f"you didn't ask for this, ignore this email — your account is "
        f"safe and the request will expire in {expires_minutes} minutes.\n\n"
        f"To set a new password, open the game's Reset Password screen "
        f"and paste this token:\n\n"
        f"    {token}\n\n"
        f"Or visit: {link}\n\n"
        f"This token expires in {expires_minutes} minutes.\n\n"
        f"— The VikingVale Server\n"
    )
    html = (
        f"<p>Hail <b>{username}</b>,</p>"
        f"<p>A password reset was requested for your VikingVale account. "
        f"If you didn't ask for this, you can ignore this email — your "
        f"account is safe and the request will expire in "
        f"{expires_minutes} minutes.</p>"
        f"<p>To set a new password, open the game's <b>Reset Password</b> "
        f"screen and paste this token:</p>"
        f"<pre style='font-size:14px;padding:8px;background:#222;"
        f"color:#f0c060;border-radius:4px;'>{token}</pre>"
        f"<p>Or visit <a href='{link}'>{link}</a>.</p>"
        f"<p>This token expires in {expires_minutes} minutes.</p>"
        f"<p>— The VikingVale Server</p>"
    )
    return text, html


def build_password_changed_email(username: str) -> tuple[str, str]:
    when = time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime())
    text = (
        f"Hail {username},\n\n"
        f"Your VikingVale password was just changed at {when}.\n\n"
        f"If this wasn't you, contact the server admin immediately — your "
        f"account may be compromised.\n\n"
        f"— The VikingVale Server\n"
    )
    html = (
        f"<p>Hail <b>{username}</b>,</p>"
        f"<p>Your VikingVale password was just changed at <b>{when}</b>.</p>"
        f"<p>If this wasn't you, contact the server admin immediately — "
        f"your account may be compromised.</p>"
        f"<p>— The VikingVale Server</p>"
    )
    return text, html
