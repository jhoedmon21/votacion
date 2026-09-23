"""VotoPaucarpata Local Processing Engine.

Watches ./whatsapp_actas_input/ for incoming images, runs Vision AI OCR,
persists to the database, and moves the image to ./processed/ or ./requires_review/.

Usage:
    python processor.py
"""
import logging
import shutil
import sys
import time
from pathlib import Path

from watchdog.events import FileSystemEventHandler
from watchdog.observers import Observer

from app.core.config import settings
from app.core.database import SessionLocal
from app.core.models import Base
from app.core.database import engine
from app.services.processor import ensure_seed_data, save_acta
from app.services.storage import storage_service
from app.services.vision import parse_acta

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
logger = logging.getLogger("processor")

VALID_EXTS = {".jpg", ".jpeg", ".png", ".webp", ".bmp"}

Base.metadata.create_all(bind=engine)


class ActaHandler(FileSystemEventHandler):
    def on_created(self, event):
        if event.is_directory:
            return
        path = Path(event.src_path)
        if path.suffix.lower() not in VALID_EXTS:
            return
        self._process(path)

    def _process(self, path: Path):
        # Give the writing process time to finish flushing the file
        time.sleep(0.5)
        if not path.exists():
            return
        logger.info("Processing: %s", path)
        try:
            result = parse_acta(str(path))
            image_url = storage_service.upload(str(path))
            db = SessionLocal()
            try:
                ensure_seed_data(db)
                table = save_acta(db, result, image_url)
            finally:
                db.close()

            dest_dir = (
                Path(settings.review_dir)
                if table.requires_review
                else Path(settings.processed_dir)
            )
            dest_dir.mkdir(parents=True, exist_ok=True)
            shutil.move(str(path), dest_dir / path.name)
            logger.info(
                "Mesa %s -> %s (confidence=%.2f)",
                table.numero_mesa,
                "requires_review" if table.requires_review else "processed",
                table.ocr_confidence,
            )
        except Exception as e:  # noqa: BLE001
            logger.exception("Failed to process %s: %s", path, e)
            review = Path(settings.review_dir)
            review.mkdir(parents=True, exist_ok=True)
            try:
                shutil.move(str(path), review / path.name)
            except Exception:  # noqa: BLE001
                pass


def main():
    watch_dir = Path(settings.watch_dir)
    watch_dir.mkdir(parents=True, exist_ok=True)
    Path(settings.processed_dir).mkdir(parents=True, exist_ok=True)
    Path(settings.review_dir).mkdir(parents=True, exist_ok=True)

    handler = ActaHandler()
    observer = Observer()
    observer.schedule(handler, str(watch_dir), recursive=False)
    observer.start()
    logger.info("Watching %s for incoming actas...", watch_dir)
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        observer.stop()
    observer.join()


if __name__ == "__main__":
    main()