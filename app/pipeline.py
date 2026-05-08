import asyncio
import json
from datetime import datetime
import structlog
from app.shims.llm_shim import LLMShim
from app.shims.search_shim import SearchShim
from app.core.models import ResearchRun
from app.archive import save_research

logger = structlog.get_logger()

class ResearchPipeline:
    def __init__(self):
        self.llm = LLMShim()
        self.search = SearchShim()

    async def run(self, query: str) -> str:
        logger.info("Starting research pipeline", query=query)

        # 1. Generate 8-12 powerful queries (structured JSON) with retry fallback
        q_prompt = f"""Generate 8-12 advanced search queries for: {query}
Return ONLY a valid JSON array of strings. Use operators, date ranges, site:, -exclude, etc."""
        raw_queries = await self.llm.invoke(q_prompt, json_mode=True, temperature=0.2)
        
        try:
            # Gemma sometimes adds extra text → strip and parse safely
            cleaned = raw_queries.strip().strip("```json").strip("```")
            queries = json.loads(cleaned)
            if not isinstance(queries, list):
                raise ValueError("Not a list")
        except Exception as e:
            logger.warning("JSON parse failed, falling back to simple split", error=str(e))
            queries = [q.strip() for q in raw_queries.split("\n") if q.strip()][:12]

        # 2. Parallel search (max 8 concurrent)
        results = await self.search.search_parallel(queries)

        # 3. Synthesize report
        context = "\n\n".join([f"Source: {r.title}\n{r.snippet}\nURL: {r.url}" for r in results])
        synth_prompt = f"""Synthesize a comprehensive, unbiased Markdown research report on: {query}

Context:
{context}

Use natural Markdown. Cite sources by URL inline. Be factual and cite every claim."""
        report_md = await self.llm.invoke(synth_prompt, temperature=0.4)

        # 4. Save
        run = ResearchRun(
            query=query,
            timestamp=datetime.utcnow(),
            report_markdown=report_md,
            raw_results=results
        )
        await save_research(run)

        logger.info("Research complete", sources=len(results), run_id=run.id)
        return report_md
