import httpx
import asyncio
import structlog
from typing import List, Optional

logger = structlog.get_logger()

class LLMShim:
    def __init__(self, model: str = "gemma4:e4b", base_url: str = "http://localhost:11434"):
        self.model = model
        self.base_url = base_url
        self.client = httpx.AsyncClient(timeout=180.0, limits=httpx.Limits(max_connections=20))

    async def invoke(self, prompt: str, temperature: float = 0.3, json_mode: bool = False) -> str:
        payload = {
            "model": self.model,
            "messages": [{"role": "user", "content": prompt}],
            "options": {"temperature": temperature, "num_ctx": 32768},
            "stream": False
        }
        if json_mode:
            payload["format"] = "json"

        for attempt in range(3):
            try:
                resp = await self.client.post(f"{self.base_url}/api/chat", json=payload)
                resp.raise_for_status()
                data = resp.json()
                return data["message"]["content"]
            except httpx.HTTPStatusError as e:
                error_body = e.response.text if e.response else str(e)
                logger.warning("LLM HTTP error", attempt=attempt, status=e.response.status_code, body=error_body)
                await asyncio.sleep(2 ** attempt)
            except Exception as e:
                logger.warning("LLM retry", attempt=attempt, error=str(e))
                await asyncio.sleep(2 ** attempt)
        raise RuntimeError(f"LLM invoke failed after retries (last error: {error_body if 'error_body' in locals() else str(e)})")

    async def close(self):
        await self.client.aclose()
