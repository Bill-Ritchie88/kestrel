"""
Project Kestrel - AI Agent Tier.

The agent holds no database credentials and cannot write to the database. It
can only call the REST tier, and only while carrying a session token that the
passenger obtained by authenticating. This is the boundary that keeps a
nondeterministic language model from mutating transactional state directly.
"""

import os
from contextvars import ContextVar

import httpx
from dotenv import load_dotenv
from langchain_core.messages import AIMessage, HumanMessage, SystemMessage, ToolMessage
from langchain_core.tools import tool
from langchain_google_genai import ChatGoogleGenerativeAI

load_dotenv()

FASTAPI_BASE_URL = os.getenv("FASTAPI_BASE_URL", "http://127.0.0.1:8000")
MAX_TOOL_ITERATIONS = 5

gemini_api_key = os.getenv("GOOGLE_API_KEY") or os.getenv("GEMINI_API_KEY")
if not gemini_api_key:
    raise ValueError("Missing GOOGLE_API_KEY in .env file.")

http_client = httpx.Client(timeout=10.0)

# The session token lives in a context variable rather than a tool argument.
# If it were an argument, the language model would be able to invent one.
_session_token: ContextVar[str | None] = ContextVar("session_token", default=None)


def _auth_headers() -> dict[str, str]:
    token = _session_token.get()
    if not token:
        raise RuntimeError("No authenticated session. Call authenticate() first.")
    return {"Authorization": f"Bearer {token}"}


def authenticate(pnr_code: str, last_name: str) -> dict:
    """
    Exchange PNR + surname for a session token and bind it to this context.

    Called by the application before the agent runs, never by the agent itself:
    credentials must not pass through the model.
    """
    response = http_client.post(
        f"{FASTAPI_BASE_URL}/api/auth/session",
        json={"pnr_code": pnr_code, "last_name": last_name},
    )
    if response.status_code != 200:
        raise PermissionError(response.json().get("detail", "Authentication failed."))

    data = response.json()
    _session_token.set(data["access_token"])
    return data["passenger"]


# ---------------------------------------------------------------------------
# Tools
# ---------------------------------------------------------------------------


@tool
def find_alternative_flights_tool() -> str:
    """
    Lists the recovery flights currently available to the authenticated
    passenger, with their flight IDs, flight numbers, departure times and
    remaining seats. Call this FIRST whenever a passenger asks to be rebooked.
    Takes no arguments; the passenger's booking is already known.
    """
    try:
        response = http_client.get(
            f"{FASTAPI_BASE_URL}/api/flights/alternatives", headers=_auth_headers()
        )
        if response.status_code != 200:
            return f"FAILED: {response.json().get('detail', 'Unknown error')}"

        data = response.json()
        if data["count"] == 0:
            return (
                "NO_OPTIONS: There are no alternative flights with available seats "
                "on this route. Escalate to a human agent."
            )

        lines = [
            f"- {f['flight_number']} departing {f['departure_time']}, "
            f"{f['available_seats']} seat(s) left, flight_id={f['flight_id']}"
            for f in data["alternatives"]
        ]
        return "AVAILABLE FLIGHTS:\n" + "\n".join(lines)
    except Exception as exc:
        return f"ERROR: Could not reach backend server. Detail: {exc}"


@tool
def reaccommodate_passenger_tool(target_flight_id: str) -> str:
    """
    Rebooks the authenticated passenger onto a specific recovery flight.
    The target_flight_id MUST come from a previous call to
    find_alternative_flights_tool. Never guess or invent a flight ID.
    """
    try:
        response = http_client.post(
            f"{FASTAPI_BASE_URL}/api/reaccommodate",
            json={"target_flight_id": target_flight_id},
            headers=_auth_headers(),
        )
        data = response.json()
        if response.status_code == 200:
            return (
                f"SUCCESS: Seat {data['assigned_seat']} assigned. {data['message']}"
            )
        return f"FAILED: {data.get('detail', 'Unknown error')}"
    except Exception as exc:
        return f"ERROR: Could not reach backend server. Detail: {exc}"


tools = [find_alternative_flights_tool, reaccommodate_passenger_tool]
tools_by_name = {t.name: t for t in tools}

llm = ChatGoogleGenerativeAI(
    model="gemini-flash-latest", temperature=0, api_key=gemini_api_key
)
llm_with_tools = llm.bind_tools(tools)

SYSTEM_PROMPT = (
    "You are Project Kestrel's AI Airline Operations Assistant for Kenya Airways. "
    "The passenger is already authenticated; never ask for or accept a PNR code. "
    "To rebook someone, first call find_alternative_flights_tool to see real "
    "options, then call reaccommodate_passenger_tool with a flight_id taken "
    "verbatim from those results. Never invent a flight ID. If no options are "
    "returned, tell the passenger you are escalating to a human agent. "
    "State only what the tools return; do not promise compensation, upgrades or "
    "policy entitlements you have not retrieved."
)


def run_agent(user_query: str) -> str:
    """
    Bounded tool-calling loop. Replaces the previous single-shot fast path,
    which could not support a two-step workflow because it returned after the
    first tool result without letting the model act on it.
    """
    messages: list = [
        SystemMessage(content=SYSTEM_PROMPT),
        HumanMessage(content=user_query),
    ]

    for _ in range(MAX_TOOL_ITERATIONS):
        ai_msg: AIMessage = llm_with_tools.invoke(messages)
        messages.append(ai_msg)

        if not ai_msg.tool_calls:
            return _extract_text(ai_msg)

        for tool_call in ai_msg.tool_calls:
            selected = tools_by_name.get(tool_call["name"])
            if selected is None:
                output = f"ERROR: Unknown tool '{tool_call['name']}'."
            else:
                output = selected.invoke(tool_call["args"])

            print(f"\n[TOOL CALL] {tool_call['name']} args={tool_call['args']}")
            print(f"[TOOL RESULT] {output}\n")
            messages.append(
                ToolMessage(content=str(output), tool_call_id=tool_call["id"])
            )

    return (
        "I was unable to complete this automatically. Transferring you to a "
        "human agent with a summary of your case."
    )


def _extract_text(msg: AIMessage) -> str:
    if isinstance(msg.content, list):
        return "".join(
            block.get("text", "") for block in msg.content if isinstance(block, dict)
        )
    return str(msg.content)


if __name__ == "__main__":
    print("\n--- Project Kestrel AI Agent Online ---")

    passenger = authenticate(pnr_code="KQX89A", last_name="Otieno")
    print(f"Authenticated: {passenger['last_name']} ({passenger['rewards_tier']})")

    prompt = "My flight was cancelled. Please get me on the next available flight."
    print(f"User Request: {prompt}")

    print("--- Final Agent Response ---")
    print(run_agent(prompt))