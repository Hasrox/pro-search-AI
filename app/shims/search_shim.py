import httpx
import asyncio
from typing import List
from app.core.models import SearchResult

class SearchShim:
    def __init__(self, base_url: str = "http://localhost:8080"):
        self.base_url = base_url

    async def search_parallel(self, queries: List[str], max_results: int = 15) -> List[SearchResult]:
        """Run up to 8 queries in parallel against local SearXNG."""
        async with httpx.AsyncClient(timeout=30.0) as client:
            tasks = [self._search_one(client, q) for q in queries[:8]]
            results_list = await asyncio.gather(*tasks, return_exceptions=True)

        all_results: List[SearchResult] = []
        for res in results_list:
            if isinstance(res, list):
                all_results.extend(res)

        # URL deduplication (keeps only the best snippets)
        seen = set()
        deduped = []
        for r in all_results:
            if r.url not in seen:
                seen.add(r.url)
                deduped.append(r)
                if len(deduped) >= max_results:
                    break
        return deduped

    async def _search_one(self, client: httpx.AsyncClient, query: str) -> List[SearchResult]:
        """Single SearXNG call with robust error handling."""
        try:
            resp = await client.get(
                f"{self.base_url}/search",
                params={"q": query, "format": "json"}
            )
            resp.raise_for_status()
            data = resp.json()
            return [
                SearchResult(
                    title=r["title"],
                    url=r["url"],
                    snippet=r.get("content", "")
                )
                for r in data.get("results", [])[:10]
            ]
        except Exception as e:
            print(f"⚠️  Search failed for query '{query}': {e}")
            return []  # graceful degradation