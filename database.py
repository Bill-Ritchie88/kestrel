import os
import asyncio
import asyncpg
from pathlib import Path
from dotenv import load_dotenv

# Force load .env from the script's directory
env_path = Path(__file__).resolve().parent / ".env"
load_dotenv(dotenv_path=env_path)

DATABASE_URL = os.getenv("DATABASE_URL")

async def test_connection():
    if not DATABASE_URL:
        print("[ERROR] DATABASE_URL not found in .env file.")
        return

    print("[INFO] Connecting to Supabase PostgreSQL database via Pooler...")
    try:
        # statement_cache_size=0 is required for asyncpg with transaction/session poolers
        pool = await asyncpg.create_pool(
            dsn=DATABASE_URL, 
            min_size=1, 
            max_size=5,
            statement_cache_size=0
        )
        
        async with pool.acquire() as conn:
            version = await conn.fetchval("SELECT version();")
            print(f"[SUCCESS] Connected to: {version[:45]}...")

            # Run atomic re-accommodation test for PNR 'KQX89A'
            result = await conn.fetchrow(
                "SELECT * FROM reaccommodate_passenger_atomic($1, $2, $3);",
                'KQX89A',
                'c2eebc99-9c0b-4ef8-bb6d-6bb9bd380a33',
                'PYTHON_TEST_AGENT'
            )
            
            print("\n--- Atomic Stored Procedure Execution Result ---")
            print(f"Success: {result['success']}")
            print(f"Assigned Seat: {result['assigned_seat_number']}")
            print(f"Message: {result['message']}")
            
        await pool.close()
        print("\n[INFO] Connection pool closed successfully.")

    except Exception as e:
        print(f"[ERROR] Failed to execute query: {e}")

if __name__ == "__main__":
    asyncio.run(test_connection())