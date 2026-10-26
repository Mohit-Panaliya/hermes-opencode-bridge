"""Kilo Code ACP provider profile.

kilocode-acp does not speak OpenAI-over-HTTP: it drives an external `kilo acp`
subprocess over stdio (kilo's default transport when no --port is given). The
profile supplies its own client via :meth:`ProviderProfile.create_client`, reusing
the same ACP stdio shim as the in-tree copilot-acp provider.

Kilo free-tier / gateway models require a signed-in ``kilo`` CLI
(``kilo auth login``); the subprocess owns auth.
"""

import os
from typing import Any

from providers import register_provider
from providers.base import ProviderProfile


class KiloCodeACPProfile(ProviderProfile):
    """Kilo Code ACP --- external process, stdio transport."""

    def _resolve_client_command(self, client_kwargs: dict[str, Any]) -> str:
        command = str(client_kwargs.get("command") or "").strip()
        if command:
            return command
        for var in self.process_command_env_vars:
            value = str(os.getenv(var, "") or "").strip()
            if value:
                return value
        return self.process_command

    def _resolve_client_args(self, client_kwargs: dict[str, Any]) -> list[str]:
        passed = client_kwargs.get("args")
        if passed:
            return list(passed)
        if self.process_args_env_var:
            import shlex

            raw = str(os.getenv(self.process_args_env_var, "") or "").strip()
            if raw:
                return shlex.split(raw)
        return list(self.process_args)

    def create_client(self, **client_kwargs: Any) -> Any:
        """Build the ACP stdio shim rather than an HTTP client."""
        from agent.copilot_acp_client import CopilotACPClient

        return CopilotACPClient(
            api_key=client_kwargs.get("api_key") or self.id,
            base_url=client_kwargs.get("base_url") or self.base_url,
            command=self._resolve_client_command(client_kwargs),
            args=self._resolve_client_args(client_kwargs),
            acp_cwd=client_kwargs.get("acp_cwd") or client_kwargs.get("cwd") or None,
        )

    def fetch_models(
        self, *, api_key: str | None = None, base_url: str | None = None, timeout: float = 15.0
    ) -> list[str] | None:
        """Enabled models advertised by a short-lived ACP session (``session/new``).

        ``api_key`` / ``base_url`` are ignored: the subprocess owns auth. None when
        the CLI is missing, the session requires sign-in, or the probe fails/times out.
        """
        from hermes_cli.auth import resolve_external_process_provider_credentials

        try:
            creds = resolve_external_process_provider_credentials(self.name)
            if not str(creds.get("base_url") or "").startswith("acp://"):
                return None
            client = self.create_client(
                api_key=creds.get("api_key"), base_url=creds.get("base_url"),
                command=creds.get("command"), args=creds.get("args"))
            return client.list_models(timeout_seconds=timeout) or None
        except Exception:
            return None


kilocode_acp = KiloCodeACPProfile(
    name="kilocode-acp",
    aliases=("kilo-acp", "kilo-acp-agent"),
    display_name="Kilo Code (ACP stdio)",
    description="Kilo Code gateway/free models via a local `kilo acp` subprocess",
    api_mode="chat_completions",
    env_vars=(),  # Managed by ACP subprocess (kilo CLI owns auth)
    base_url="acp://kilocode",
    auth_type="external_process",
    process_command="kilo",
    process_args=("acp",),
    process_command_env_vars=("HERMES_KILOCODE_ACP_COMMAND",),
    process_args_env_var="HERMES_KILOCODE_ACP_ARGS",
    default_aux_model="kilo/~z-ai/glm-flash-latest",
)

register_provider(kilocode_acp)