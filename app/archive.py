import json
from pathlib import Path
import asyncio
from uuid import uuid4
import structlog
from app.core.models import ResearchRun
from qdrant_client import QdrantClient
from qdrant_client.http.models import PointStruct, Distance, VectorParams, CreateCollection

logger = structlog.get_logger()
ARCHIVE_DIR = Path("./research_archive")
ARCHIVE_DIR.mkdir(exist_ok=True)

async def save_research(run: ResearchRun):
    run.id = str(uuid4())
    timestamp = run.timestamp.strftime("%Y%m%d_%H%M%S")
    base = ARCHIVE_DIR / timestamp
    base.mkdir(exist_ok=True)

    (base / "report.md").write_text(run.report_markdown)
    (base / "raw_results.json").write_text(json.dumps([r.model_dump() for r in run.raw_results], indent=2))

    # Qdrant – create collection if missing (placeholder 1536-dim vector)
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
    logger.info("Research saved", run_id=run.id, archive_path=str(base))
