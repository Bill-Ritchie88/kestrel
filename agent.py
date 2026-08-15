import os
import httpx
from dotenv import load_dotenv
from langchain_core.tools import tool
from langchain_google_genai import ChatGoogleGenerativeAI
from langchain_core.messages import HumanMessage, SystemMessage

# Load environment variables
load_dotenv()

FASTAPI_BASE_URL = "http://127.0.0.1:8000"

gemini_api_key = os.getenv("GOOGLE_API_KEY") or os.getenv("GEMINI_API_KEY")
if not gemini_api_key:
    raise ValueError("Missing GOOGLE_API_KEY in .env file.")

# Persistent HTTP connection pool to avoid TCP handshake delays
http_client = httpx.Client(timeout=10.0)

@tool
def reaccommodate_passenger_tool(pnr_code: str, target_flight_id: str) -> str:
    """
    Re-accommodates a passenger with a disrupted flight onto a new target flight.
    Use this tool whenever a passenger provides their PNR booking code and wants 
    to be rebooked onto a specific target flight UUID.
    """
    try:
        response = http_client.post(
            f"{FASTAPI_BASE_URL}/api/reaccommodate",
            json={
                "pnr_code": pnr_code,
                "target_flight_id": target_flight_id,
                "agent_id": "GEMINI_REBOOKING_AGENT"
            }
        )
        data = response.json()
        if response.status_code == 200:
            return f"SUCCESS: Passenger {pnr_code} assigned seat {data['assigned_seat']}. Message: {data['message']}"
        else:
            return f"FAILED: {data.get('detail', 'Unknown error')}"
    except Exception as e:
        return f"ERROR: Could not reach backend server. Detail: {str(e)}"

# Register tool
tools = [reaccommodate_passenger_tool]
tools_by_name = {t.name: t for t in tools}

# Initialize Gemini model
llm = ChatGoogleGenerativeAI(
    model="gemini-flash-latest",
    temperature=0,
    api_key=gemini_api_key
)
llm_with_tools = llm.bind_tools(tools)

def run_agent(user_query: str):
    messages = [
        SystemMessage(content="You are Project Kestrel's AI Airline Operations Assistant. "
                              "Help passengers rebook onto recovery flights using the available tools."),
        HumanMessage(content=user_query)
    ]
    
    # 1. Single LLM call (Gemini identifies tool + arguments)
    ai_msg = llm_with_tools.invoke(messages)
    
    # 2. Fast-Path: Execute tool and return formatted string directly (Saves ~2 seconds)
    if ai_msg.tool_calls:
        for tool_call in ai_msg.tool_calls:
            selected_tool = tools_by_name[tool_call["name"].lower()]
            tool_output = selected_tool.invoke(tool_call["args"])
            print(f"\n[AGENT TOOL CALL] Executed '{tool_call['name']}' with args: {tool_call['args']}")
            print(f"[TOOL RESULT] {tool_output}\n")
            return f"Reaccommodation Complete! {tool_output}"
            
    # Clean fallback text parser
    if isinstance(ai_msg.content, list):
        return "".join([block.get("text", "") for block in ai_msg.content if isinstance(block, dict)])
    return str(ai_msg.content)

if __name__ == "__main__":
    print("\n--- Project Kestrel Gemini AI Agent Online ---")
    
    user_prompt = (
        "My flight was cancelled. My PNR is KQX89A. "
        "Please rebook me onto target flight c2eebc99-9c0b-4ef8-bb6d-6bb9bd380a33."
    )
    print(f"User Request: {user_prompt}")
    
    agent_response = run_agent(user_prompt)
    print("--- Final Agent Response ---")
    print(agent_response)