import json
from pathlib import Path
import asyncio
from uuid import uuid4
import structlog
from app.core.models import ResearchRun
from qdrant_client import QdrantClient
from qdrant_client.http.models import PointStruct, Distance, VectorParams, CreateCollection
import aiofiles

logger = structlog.get_logger()
ARCHIVE_DIR = Path("./research_archive")
ARCHIVE_DIR.mkdir(exist_ok=True)

async def save_research(run: ResearchRun):
    run.id = str(uuid4())
    timestamp = run.timestamp.strftime("%Y%m%d_%H%M%S")
    base = ARCHIVE_DIR / timestamp
    base.mkdir(exist_ok=True)

    # Async file writes (zero blocking)
    async with aiofiles.open(base / "report.md", "w") as f:
        await f.write(run.report_markdown)
    async with aiofiles.open(base / "raw_results.json", "w") as f:
        await f.write(json.dumps([r.model_dump() for r in run.raw_results], indent=2))

    # Qdrant (sync client wrapped in thread for now – future async client possible)
    def _qdrant_upsert():
        client = QdrantClient("localhost", port=6333)
        if not client.collection_exists("research_history"):
            client.create_collection(
                collection_name="research_history",
                vectors_config=VectorParams(size=1536, distance=Distance.COSINE)
            )
        client.upsert(
            collection_name="research_history",
            points=[PointStruct(id=run.id, vector=[0.0] * 1536, payload=run.model_dump())]
        )
        client.close()  # explicit cleanup

    await asyncio.to_thread(_qdrant_upsert)
    logger.info("Research saved", run_id=run.id, archive_path=str(base))
