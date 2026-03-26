FROM python:3.11

WORKDIR /app

# Install system dependencies required for ML libraries
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Copy requirements and install dependencies (no cache for security)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Additional ML dependencies for the pipeline
RUN pip install --no-cache-dir \
    numpy==1.24.3 \
    scikit-learn==1.3.0 \
    transformers==4.30.2 \
    torch==2.0.1 \
    spacy==3.5.0

# Download spaCy model
RUN python -m spacy download en_core_web_sm

# Copy application code
COPY . .

# No exposed ports (batch job)

# Run pipeline crawler
CMD ["python", "-m", "upnews_pipeline.crawl"]
