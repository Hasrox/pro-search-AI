from pydantic import BaseModel
from datetime import datetime
from typing import List
import uuid

class SearchResult(BaseModel):
    title: str
    url: str
    snippet: str

class ResearchRun(BaseModel):
    id: str = None  # populated on save
    query: str
    timestamp: datetime
    report_markdown: str
    raw_results: List[SearchResult]
