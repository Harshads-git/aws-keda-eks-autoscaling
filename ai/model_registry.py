"""
ai/model_registry.py — Model Versioning and Persistence
=========================================================

Saves and loads the best-performing model (selected by ModelEvaluator) as a
versioned pickle file. Tracks accuracy metadata alongside the model object so
the KEDA External Scaler can decide whether to trust the current model or
fall back to reactive scaling.

Why pickle over ONNX / MLflow:
  pickle: zero dependencies, instant save/load, sufficient for scikit-learn
          and our small ARIMA model. No model server required.
  ONNX: cross-language format, better for serving; overkill for this project.
  MLflow: full MLOps platform with experiment tracking; worth adding at Day 50+.

Registry layout on disk:
  ai/registry/
    current_model.pkl          ← latest best model object
    current_metadata.json      ← version, MAPE, model_name, timestamp
    history/
      model_20260924_185500.pkl  ← archived prior versions
      model_20260924_185500.json

Usage:
    from ai.model_registry import ModelRegistry, ModelMetadata

    registry = ModelRegistry(registry_dir="ai/registry")

    # Save after evaluation
    metadata = ModelMetadata(
        model_name="arima",
        version="20260924_185500",
        mape=11.7,
        n_backtest_steps=67,
    )
    registry.save(model_object, metadata)

    # Load at startup (KEDA External Scaler)
    model, metadata = registry.load()
    if metadata and metadata.mape < 20.0:
        depth = model.predict(...)
"""

import json
import logging
import os
import pickle
import shutil
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional, Tuple

logger = logging.getLogger("keda-demo")

DEFAULT_REGISTRY_DIR = Path(__file__).parent / "registry"


@dataclass
class ModelMetadata:
    """
    Metadata stored alongside the serialised model object.

    Persisted as JSON so it can be read without loading the full pickle.
    """
    model_name: str
    """'linear_regression', 'arima', or 'reactive'."""

    version: str
    """ISO-8601-like version string: YYYYMMDD_HHMMSS."""

    mape: float
    """Mean Absolute Percentage Error on held-out backtest data."""

    n_backtest_steps: int = 0
    """Number of walk-forward steps used to compute MAPE."""

    horizon_steps: int = 3
    """Forecast horizon used during backtesting."""

    trained_at: str = ""
    """UTC ISO-8601 timestamp of when training/evaluation occurred."""

    comparison_lr_mape: float = float("inf")
    """LR MAPE at time of selection (for audit trail)."""

    comparison_arima_mape: float = float("inf")
    """ARIMA MAPE at time of selection (for audit trail)."""


class ModelRegistry:
    """
    Simple filesystem-based model registry.

    Saves, loads, and archives versioned model checkpoints.
    Thread-safe for single-writer, multi-reader (KEDA External Scaler) use.

    Example directory layout after three saves:
        registry/
            current_model.pkl
            current_metadata.json
            history/
                model_20260924_120000.pkl
                model_20260924_120000.json
                model_20260924_180000.pkl
                model_20260924_180000.json
    """

    CURRENT_MODEL_FILE = "current_model.pkl"
    CURRENT_META_FILE = "current_metadata.json"
    HISTORY_DIR = "history"

    def __init__(self, registry_dir: Optional[Path] = None) -> None:
        self._dir = Path(registry_dir or DEFAULT_REGISTRY_DIR)
        self._history_dir = self._dir / self.HISTORY_DIR
        self._dir.mkdir(parents=True, exist_ok=True)
        self._history_dir.mkdir(parents=True, exist_ok=True)

    # ── Public API ─────────────────────────────────────────────────────────────

    def save(self, model: Any, metadata: ModelMetadata) -> Path:
        """
        Persist a model and its metadata as the current best model.

        Steps:
          1. Archive the existing current model (if any) to history/.
          2. Write the new model to current_model.pkl.
          3. Write metadata to current_metadata.json.

        Args:
            model: Any serialisable Python object (predictor instance, etc.).
            metadata: ModelMetadata populated from EvaluationResult.

        Returns:
            Path to the written current_model.pkl.
        """
        if not metadata.trained_at:
            metadata.trained_at = datetime.now(timezone.utc).isoformat()

        # Archive existing current model before overwriting
        self._archive_current()

        model_path = self._dir / self.CURRENT_MODEL_FILE
        meta_path = self._dir / self.CURRENT_META_FILE

        # Write model atomically: write to temp, then rename
        tmp_model = model_path.with_suffix(".pkl.tmp")
        with open(tmp_model, "wb") as f:
            pickle.dump(model, f, protocol=pickle.HIGHEST_PROTOCOL)
        tmp_model.replace(model_path)

        # Write metadata as indented JSON (human-readable)
        with open(meta_path, "w") as f:
            json.dump(asdict(metadata), f, indent=2)

        logger.info(
            "Model saved to registry",
            extra={
                "model_name": metadata.model_name,
                "version": metadata.version,
                "mape": metadata.mape,
                "path": str(model_path),
            },
        )
        return model_path

    def load(self) -> Tuple[Optional[Any], Optional[ModelMetadata]]:
        """
        Load the current best model and its metadata.

        Returns:
            (model, metadata) tuple. Both are None if no model has been saved.

        Raises:
            Nothing — all errors are caught and logged; returns (None, None).
        """
        model_path = self._dir / self.CURRENT_MODEL_FILE
        meta_path = self._dir / self.CURRENT_META_FILE

        if not model_path.exists():
            logger.info("No model found in registry", extra={"registry_dir": str(self._dir)})
            return None, None

        try:
            with open(model_path, "rb") as f:
                model = pickle.load(f)
            with open(meta_path, "r") as f:
                meta_dict = json.load(f)
            metadata = ModelMetadata(**meta_dict)
            logger.info(
                "Model loaded from registry",
                extra={
                    "model_name": metadata.model_name,
                    "version": metadata.version,
                    "mape": metadata.mape,
                },
            )
            return model, metadata
        except Exception as e:
            logger.error(
                "Failed to load model from registry",
                extra={"error": str(e), "path": str(model_path)},
            )
            return None, None

    def load_metadata(self) -> Optional[ModelMetadata]:
        """
        Load only the metadata (without deserialising the model pickle).

        Useful for quick confidence checks before deciding to load the full model.
        """
        meta_path = self._dir / self.CURRENT_META_FILE
        if not meta_path.exists():
            return None
        try:
            with open(meta_path, "r") as f:
                meta_dict = json.load(f)
            return ModelMetadata(**meta_dict)
        except Exception as e:
            logger.warning("Failed to read metadata", extra={"error": str(e)})
            return None

    def list_history(self) -> list:
        """Return a sorted list of archived model version strings (newest first)."""
        try:
            jsons = sorted(
                self._history_dir.glob("*.json"),
                key=lambda p: p.stem,
                reverse=True,
            )
            history = []
            for j in jsons:
                with open(j) as f:
                    history.append(json.load(f))
            return history
        except Exception:
            return []

    def is_model_trustworthy(self, mape_threshold: float = 20.0) -> bool:
        """
        Quick check: is the current model's MAPE within an acceptable range?

        Used by the KEDA External Scaler to decide whether to use predictions
        or fall back to the actual queue depth.

        Args:
            mape_threshold: Maximum acceptable MAPE (default 20%).

        Returns:
            True if a model is loaded AND its MAPE < mape_threshold.
        """
        metadata = self.load_metadata()
        if metadata is None:
            return False
        return metadata.mape < mape_threshold

    # ── Private helpers ────────────────────────────────────────────────────────

    def _archive_current(self) -> None:
        """Move the current model/metadata to the history/ directory."""
        model_path = self._dir / self.CURRENT_MODEL_FILE
        meta_path = self._dir / self.CURRENT_META_FILE

        if not model_path.exists():
            return

        # Use the existing version string as the archive filename
        version = "unknown"
        if meta_path.exists():
            try:
                with open(meta_path) as f:
                    meta = json.load(f)
                version = meta.get("version", "unknown")
            except Exception:
                pass

        archived_model = self._history_dir / f"model_{version}.pkl"
        archived_meta = self._history_dir / f"model_{version}.json"

        shutil.copy2(model_path, archived_model)
        if meta_path.exists():
            shutil.copy2(meta_path, archived_meta)

        logger.debug("Archived previous model", extra={"version": version})

    @staticmethod
    def make_version() -> str:
        """Generate a version string from the current UTC timestamp."""
        return datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
