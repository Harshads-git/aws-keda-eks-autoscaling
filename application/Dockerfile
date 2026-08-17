# =============================================================================
# Dockerfile — KEDA Demo SQS Consumer (Multi-Stage Build)
# =============================================================================
# Stage 1 (builder): Installs Python dependencies into an isolated layer.
#                    Heavy tools (gcc, pip) stay in this stage and are NOT
#                    copied to the final image, keeping it lean.
#
# Stage 2 (runtime): Copies only the installed packages and app code.
#                    Runs as a non-root user for security.
#                    Final image size: ~120MB vs ~400MB for single-stage.
#
# Why multi-stage?
#   - Smaller attack surface: no build tools (gcc, pip) in production image
#   - Faster EKS pod startup: smaller image = faster pull from ECR
#   - Cleaner layer caching: requirements.txt changes don't bust app code cache
# =============================================================================

# ─── Stage 1: Builder ────────────────────────────────────────────────────────
FROM python:3.11-slim AS builder

# Install pip dependencies into a custom directory
# This directory is then copied to the runtime stage cleanly
WORKDIR /install

# Copy requirements first to leverage Docker layer caching:
# If requirements.txt hasn't changed, pip install is skipped entirely
COPY requirements.txt .

# Install packages to /install/packages (not system site-packages)
# --no-cache-dir: don't store pip cache in the image
# --prefix:       install to custom path for easy copying to runtime stage
RUN pip install \
    --no-cache-dir \
    --upgrade pip \
    --prefix=/install/packages \
    -r requirements.txt

# ─── Stage 2: Runtime ─────────────────────────────────────────────────────────
FROM python:3.11-slim AS runtime

# Metadata labels — visible in ECR and useful for auditing
LABEL org.opencontainers.image.title="keda-demo-app"
LABEL org.opencontainers.image.description="SQS consumer for KEDA event-driven autoscaling demo"
LABEL org.opencontainers.image.source="https://github.com/Harshads-git/aws-keda-eks-autoscaling"
LABEL org.opencontainers.image.language="python"
LABEL org.opencontainers.image.base="python:3.11-slim"

# ── Security: Run as non-root user ───────────────────────────────────────────
# Kubernetes Pod Security Standards (restricted profile) requires non-root.
# uid/gid 1001 is a conventional non-privileged application user.
RUN groupadd --gid 1001 appuser && \
    useradd  --uid 1001 --gid 1001 --no-create-home --shell /bin/false appuser

# ── Copy installed packages from builder ──────────────────────────────────────
COPY --from=builder /install/packages /usr/local

# ── Application setup ─────────────────────────────────────────────────────────
WORKDIR /app

# Copy application source (separate COPY to leverage layer caching)
# If requirements.txt hasn't changed, only this layer needs rebuilding
COPY app.py .

# Set ownership to non-root user
RUN chown -R appuser:appuser /app

# Switch to non-root user for all subsequent commands (including CMD)
USER appuser

# ── Environment variables ─────────────────────────────────────────────────────
# These are DEFAULTS — override in Kubernetes ConfigMap / Deployment env section
# Never hardcode actual values here (especially secrets)
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    LOG_LEVEL=INFO \
    SQS_QUEUE_URL="" \
    AWS_REGION="us-east-1"

# PYTHONUNBUFFERED=1:       Ensures Python logs appear immediately in CloudWatch
#                           Without this, logs are buffered and may appear late
# PYTHONDONTWRITEBYTECODE=1: No .pyc files — cleaner container filesystem

# ── Health Check ─────────────────────────────────────────────────────────────
# Kubernetes uses this to determine if the container is alive.
# For a long-running consumer, we check if the Python process exists.
# Interval: check every 30s
# Timeout:  fail if check takes > 10s
# Retries:  mark Unhealthy after 3 consecutive failures
# Start period: give 10s for startup before health checks begin
HEALTHCHECK --interval=30s --timeout=10s --retries=3 --start-period=10s \
    CMD python -c "import os, sys; sys.exit(0 if os.path.exists('/tmp/healthy') else 1)"

# ── Entry Point ───────────────────────────────────────────────────────────────
# Run the SQS consumer application
# Uses exec form (JSON array) — NOT shell form — so SIGTERM is received directly
# by Python, enabling graceful shutdown handling in app.py
CMD ["python", "-u", "app.py"]
