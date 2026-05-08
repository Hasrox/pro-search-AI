import sys
from pathlib import Path

# === ZERO-FOOTPRINT PACKAGE BOOTSTRAP (Windows-safe) ===
PROJECT_ROOT = Path(__file__).parent.resolve()
sys.path.insert(0, str(PROJECT_ROOT))
# =======================================================

import asyncio
from app.pipeline import ResearchPipeline

async def main():
    pipe = ResearchPipeline()
    report = await pipe.run("latest breakthroughs in fully local uncensored AI search pipelines")
    print(report[:800] + "\n... (full report + raw data saved in ./research_archive/)")

if __name__ == "__main__":
    asyncio.run(main())
