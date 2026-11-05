"""Talk to the Copilot Studio agent with Microsoft's Python SDK.

Called from R (R/agent.R) through reticulate. Two functions:
  ask_agent()        - send one message in a new conversation, return the agent's reply text
  get_token_local()  - sign in through the browser to get a token, for testing on your own computer
"""

import asyncio

import aiohttp
from microsoft_agents.activity import ActivityTypes
from microsoft_agents.copilotstudio.client import ConnectionSettings, CopilotClient


def _settings(direct_connect_url: str, timeout_seconds: float) -> ConnectionSettings:
    return ConnectionSettings(
        environment_id="",  # not needed with a direct connect URL
        agent_identifier="",
        direct_connect_url=direct_connect_url,
        client_session_settings={"timeout": aiohttp.ClientTimeout(total=timeout_seconds)},
    )


async def _ask(direct_connect_url: str, token: str, text: str, timeout_seconds: float) -> str:
    client = CopilotClient(_settings(direct_connect_url, timeout_seconds), token)

    # Start a fresh conversation for each paper so papers don't affect each other.
    conversation_id = None
    async for activity in client.start_conversation(emit_start_conversation_event=True):
        if activity and activity.conversation and activity.conversation.id:
            conversation_id = activity.conversation.id

    replies = []
    async for activity in client.ask_question(text, conversation_id):
        if activity and activity.type == ActivityTypes.message and activity.text:
            replies.append(activity.text)
    return "\n".join(replies)


def ask_agent(direct_connect_url: str, token: str, text: str, timeout_seconds: float = 900) -> str:
    """Send `text` to the agent and return everything it replies, joined by newlines."""
    return asyncio.run(_ask(direct_connect_url, token, text, float(timeout_seconds)))


def get_token_local(tenant_id: str, client_id: str, direct_connect_url: str, cache_path: str = "") -> str:
    """Sign in through the browser (first time) or from the cache, and return an access token.

    For local testing only. On Posit Connect the token comes from Connect's
    OAuth integration instead.
    """
    import msal

    cache = msal.SerializableTokenCache()
    if cache_path:
        try:
            with open(cache_path) as f:
                cache.deserialize(f.read())
        except FileNotFoundError:
            pass

    app = msal.PublicClientApplication(
        client_id,
        authority=f"https://login.microsoftonline.com/{tenant_id}",
        token_cache=cache,
    )
    scopes = [CopilotClient.scope_from_settings(_settings(direct_connect_url, 60))]

    result = None
    accounts = app.get_accounts()
    if accounts:
        result = app.acquire_token_silent(scopes, account=accounts[0])
    if not result:
        result = app.acquire_token_interactive(scopes=scopes)

    if cache_path and cache.has_state_changed:
        with open(cache_path, "w") as f:
            f.write(cache.serialize())

    if "access_token" not in result:
        raise RuntimeError(f"Sign-in failed: {result.get('error')}: {result.get('error_description')}")
    return result["access_token"]
