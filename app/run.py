import asyncio
from app.pipeline import ResearchPipeline

async def main():
    pipe = ResearchPipeline()
    report = await pipe.run("latest breakthroughs in fully local uncensored AI search pipelines")
    print(report[:600] + "\n... (full report + raw data saved in ./research_archive)")

if __name__ == "__main__":
    asyncio.run(main())