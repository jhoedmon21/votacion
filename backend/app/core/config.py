"""VotoPaucarpata Engine — application configuration."""
from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    database_url: str = "sqlite:///./votopaucarpata.db"

    openai_api_key: str = ""
    openai_vision_model: str = "gpt-4o-mini"

    gemini_api_key: str = ""
    gemini_vision_model: str = "gemini-2.0-flash"

    # Local OCR (Tesseract + OpenCV pre-processing / fallback)
    local_ocr_enabled: bool = True
    tesseract_cmd: str = ""  # optional: path to tesseract binary (e.g. "C:\\Program Files\\Tesseract-OCR\\tesseract.exe")

    storage_backend: str = "local"  # local | supabase | s3 | cloudinary
    storage_local_dir: str = "./storage"
    supabase_url: str = ""
    supabase_key: str = ""
    s3_bucket: str = ""
    s3_region: str = "us-east-1"
    aws_access_key_id: str = ""
    aws_secret_access_key: str = ""

    ocr_confidence_threshold: float = 0.90
    watch_dir: str = "./whatsapp_actas_input"
    processed_dir: str = "./processed"
    review_dir: str = "./requires_review"

    cors_origins: str = "http://localhost:3000,http://127.0.0.1:3000"

    # Credenciales de personeros (Fuerza Arequipeña): secreto HMAC que firma
    # el QR (FA-AREQUIPA|DNI|MESA|firma). Cambiar en producción (.env).
    credencial_qr_secret: str = "dev-fuerza-arequipena-cambiar"
    credencial_partido: str = "FUERZA AREQUIPEÑA"

    @property
    def cors_origin_list(self) -> list[str]:
        return [o.strip() for o in self.cors_origins.split(",") if o.strip()]


@lru_cache
def get_settings() -> Settings:
    return Settings()


settings = get_settings()