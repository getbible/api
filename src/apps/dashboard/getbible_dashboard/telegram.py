"""The existing Telegram channel, with acknowledged delivery for authentication."""

import json
import re
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from .config import read_settings


class DeliveryError(Exception):
    """A notification was not acknowledged; contains no bot credentials."""


class Telegram:
    def __init__(self, config_path, opener=None):
        self.config_path = config_path
        self.opener = opener or urlopen

    def _settings(self):
        settings = read_settings(self.config_path)
        enabled = settings.get("TELEGRAM_ENABLED") == "true"
        token = settings.get("TELEGRAM_BOT_TOKEN", "")
        chat = settings.get("TELEGRAM_CHAT_ID", "")
        if not (enabled and re.fullmatch(r"[0-9]+:[A-Za-z0-9_-]+", token)
                and re.fullmatch(r"-?[0-9]+|@[A-Za-z0-9_]+", chat)):
            return None
        return token, chat, settings.get("TELEGRAM_HOSTNAME", "getBible")

    @property
    def configured(self):
        return self._settings() is not None

    def send(self, title, body):
        settings = self._settings()
        if settings is None:
            raise DeliveryError("Telegram is not configured")
        token, chat, host = settings
        data = json.dumps({
            "chat_id": chat, "text": f"{title}\n{body}\n\n{host}",
            "disable_web_page_preview": True,
        }).encode()
        request = Request(
            f"https://api.telegram.org/bot{token}/sendMessage", data=data,
            headers={"Content-Type": "application/json"}, method="POST",
        )
        try:
            with self.opener(request, timeout=10) as response:
                if response.status != 200:
                    raise DeliveryError("Telegram did not acknowledge delivery")
                result = json.loads(response.read(65537))
                if result.get("ok") is not True:
                    raise DeliveryError("Telegram did not acknowledge delivery")
        except (HTTPError, URLError, TimeoutError, OSError, ValueError, TypeError):
            # HTTP exception strings contain the bot token in their URL.
            raise DeliveryError("Telegram delivery failed") from None

    def login_code(self, code, ip, challenge_id, seconds):
        self.send(
            "getBible dashboard sign-in",
            f"Client: {ip}\nChallenge: {challenge_id[:8]}\n"
            f"One-use code (valid {seconds} seconds after delivery):\n{code}\n"
            "Only enter this code on your configured dashboard domain.",
        )
