import os
import asyncpg
from pathlib import Path
from contextlib import asynccontextmanager
from fastapi import FastAPI, HTTPException, status
from pydantic import BaseModel, Field
from dotenv import load_dotenv

# Load .env configuration
env_path = Path(__file__).resolve().parent / ".env"
load_dotenv(dotenv_path=env_path)

DATABASE_URL = os.getenv("DATABASE_URL")

# Global database pool reference
db_pool = None

@asynccontextmanager
async def lifespan(app: FastAPI):
    global db_pool
    print("[INFO] Initializing database connection pool...")
    db_pool = await asyncpg.create_pool(
        dsn=DATABASE_URL,
        min_size=1,
        max_size=5,
        statement_cache_size=0
    )
    yield
    print("[INFO] Closing database connection pool...")
    if db_pool:
        await db_pool.close()

app = FastAPI(
    title="Project Kestrel - Re-accommodation Engine",
    version="1.0.0",
    lifespan=lifespan
)

# Request Payload Schema
class ReaccommodateRequest(BaseModel):
    pnr_code: str = Field(..., example="KQX89A")
    target_flight_id: str = Field(..., example="c2eebc99-9c0b-4ef8-bb6d-6bb9bd380a33")
    agent_id: str = Field(default="FASTAPI_AGENT", example="AGENT_AI")
@app.get("/")
async def root():
    return {
        "status": "online",
        "system": "Project Kestrel Re-accommodation Engine",
        "docs_url": "http://127.0.0.1:8000/docs"
    }
@app.get("/health")
async def health_check():
    return {"status": "online", "database": "connected" if db_pool else "disconnected"}

@app.post("/api/reaccommodate")
async def reaccommodate_passenger(payload: ReaccommodateRequest):
    if not db_pool:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Database connection pool unavailable."
        )

    async with db_pool.acquire() as conn:
        result = await conn.fetchrow(
            "SELECT * FROM reaccommodate_passenger_atomic($1, $2, $3);",
            payload.pnr_code,
            payload.target_flight_id,
            payload.agent_id
        )

        if not result["success"]:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=result["message"]
            )

        return {
            "success": result["success"],
            "assigned_seat": result["assigned_seat_number"],
            "message": result["message"]
        }