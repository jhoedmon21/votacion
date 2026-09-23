"""Cloud storage abstraction (local / Supabase / S3)."""
import os
import shutil
import uuid
from pathlib import Path

from app.core.config import settings


class StorageService:
    def __init__(self):
        self.backend = settings.storage_backend

    def upload(self, source_path: str, filename: str | None = None) -> str:
        """Upload a file and return its public URL."""
        ext = Path(source_path).suffix or ".jpg"
        key = filename or f"{uuid.uuid4().hex}{ext}"

        if self.backend == "local":
            return self._upload_local(source_path, key)
        if self.backend == "s3":
            return self._upload_s3(source_path, key)
        if self.backend == "supabase":
            return self._upload_supabase(source_path, key)
        raise ValueError(f"Unsupported storage backend: {self.backend}")

    def _upload_local(self, source_path: str, key: str) -> str:
        dest_dir = Path(settings.storage_local_dir)
        dest_dir.mkdir(parents=True, exist_ok=True)
        dest = dest_dir / key
        shutil.copy2(source_path, dest)
        return f"/storage/{key}"

    def _upload_s3(self, source_path: str, key: str) -> str:
        import boto3
        s3 = boto3.client(
            "s3",
            region_name=settings.s3_region,
            aws_access_key_id=settings.aws_access_key_id,
            aws_secret_access_key=settings.aws_secret_access_key,
        )
        s3.upload_file(source_path, settings.s3_bucket, key)
        return f"https://{settings.s3_bucket}.s3.{settings.s3_region}.amazonaws.com/{key}"

    def _upload_supabase(self, source_path: str, key: str) -> str:
        # Requires supabase-py; minimal HTTP fallback using storage API
        import httpx
        url = f"{settings.supabase_url}/storage/v1/object/actas/{key}"
        with open(source_path, "rb") as f:
            resp = httpx.post(
                url,
                headers={"Authorization": f"Bearer {settings.supabase_key}"},
                content=f.read(),
            )
        resp.raise_for_status()
        return f"{settings.supabase_url}/storage/v1/object/public/actas/{key}"


storage_service = StorageService()