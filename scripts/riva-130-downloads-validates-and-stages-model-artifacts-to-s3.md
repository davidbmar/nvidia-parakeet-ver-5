* **OVERVIEW (1–3 sentences)**

  * This script fetches NVIDIA Riva/Parakeet ASR model artifacts, verifies their integrity/structure, and stages the validated payload into a well-defined S3 prefix so downstream deploy scripts can reliably pick them up.
  * It standardizes *where* artifacts live, *what* gets uploaded, and *how* we know the bits are good—reducing “works on my box” drift and preventing corrupted models from entering prod. ([GitHub][1])

Would you like me to proceed by **dropping this into a `.md`** you can commit next to the script?

---

# `riva-130-downloads-validates-and-stages-model-artifacts-to-s3.md`

## Purpose

Automate a **repeatable, validated** path for getting Riva/Parakeet ASR model artifacts into S3. This gives the rest of the pipeline (e.g., deploy/smoke-test on GPU instances) a single, trusted source of truth for model bits. ([GitHub][1])

## What it does (at a glance)

* **Download** one or more model tarballs/archives (e.g., Parakeet RNNT) from configured sources.
* **Validate** integrity (checksums), format (archive sanity), and **structure** (expected files/dirs).
* **Stage to S3** under a versioned prefix, write a **manifest** (+ checksums), and optionally tag/encrypt objects.
* **Emit handoff signals** (e.g., `.done`/manifest) so deploy scripts can proceed deterministically.

---

## Prerequisites

* AWS credentials with `s3:PutObject`, `s3:PutObjectTagging`, `s3:ListBucket`, `s3:GetObject`.
* A populated `.env` (no hardcoding in the script).
* `awscli`, `curl`/`wget`, `sha256sum`, `tar`, `jq` (if manifest is JSON).

---

## Required environment (expected keys)

> These are typical; adapt to your repo’s `.env` names.

* **AWS_REGION** — e.g., `us-east-1`
* **S3_STAGING_BUCKET** — target bucket for staged artifacts
* **S3_STAGING_PREFIX** — e.g., `riva/models/parakeet/1.1b/`
* **MODEL_PRIMARY_URL** — canonical download URL (NGC, signed URL, or internal mirror)
* **MODEL_FALLBACK_URL** (optional) — secondary mirror if primary fails
* **MODEL_SHA256** — expected SHA256 for the main archive
* **ARTIFACT_NAME** — logical model name (e.g., `parakeet-rnnt-1.1b-en-us`)
* **STORAGE_CLASS** (optional) — e.g., `STANDARD_IA`
* **KMS_KEY_ID** (optional) — for SSE-KMS uploads
* **UPLOAD_TAGS** (optional) — e.g., `Project=Riva,Stage=Staging,Model=Parakeet`
* **DRY_RUN** (optional) — `1` to preview actions
* **FORCE** (optional) — `1` to overwrite existing S3 keys

---

## Inputs & Outputs

**Inputs**

* Model archive(s) defined by URL(s) and expected checksums.
* `.env` for configuration.

**Outputs**

* **S3 layout** (example):
  `s3://$S3_STAGING_BUCKET/$S3_STAGING_PREFIX/$ARTIFACT_NAME/$VERSION/`
  with: `model/…` (expanded), `archive/…` (original tar), `checksums/`, `manifest.json`, and a `READY.ok` (or similar) handoff flag.
* **Local logs** and transient working directory (cleaned on success).

---

## Step-by-step flow

### 1) Initialize & safety checks

* Enable strict bash (`set -euo pipefail`), set traps for cleanup.
* Load `.env`; verify required variables.
* Create `logs/` and a timestamped log file; echo config summary for reproducibility.

**Why it matters**: Fails fast on mis-config, and every run is traceable.

---

### 2) Resolve model & working directories

* Compute a unique **work dir** (e.g., `./artifacts/$ARTIFACT_NAME/$VERSION/$DATETIME`)
* Normalize the S3 destination prefix (avoid double slashes), derive **S3 paths** for `archive/`, `model/`, `checksums/`, `manifest.json`.

**Why it matters**: Predictable paths = deterministic downstream automation.

---

### 3) Download artifacts (with retries)

* Use `curl -L` (or `wget`) with sensible **retry/backoff**.
* Save to `archive/<filename>.tar.gz` (no spaces).
* If `MODEL_FALLBACK_URL` is set and primary fails, attempt fallback.

**Why it matters**: Network blips shouldn’t break CI; fallbacks raise robustness.

---

### 4) Integrity checks (checksum)

* Run `sha256sum` on the downloaded file; **compare** to `$MODEL_SHA256`.
* If mismatch, **abort** (optionally keep file for post-mortem).

**Why it matters**: Prevents corrupted/partial downloads from contaminating S3.

---

### 5) Archive sanity & extraction

* Quick `tar -tzf` to verify index; then extract to `model/`.
* Enforce **expected structure** (e.g., presence of `config.pbtxt`, `riva/`, `triton/` or equivalent directories—adjust to your model’s spec).
* Optionally normalize permissions (e.g., `chmod -R a+rX`).

**Why it matters**: Early structure checks catch wrong archives or upstream changes.

---

### 6) Deep validation (optional but recommended)

* Walk the tree to ensure required files exist (e.g., encoder/decoder engines, vocabulary, tokenizer, etc.).
* Verify sizes aren’t zero; optionally check **model version** string inside configs.
* Generate **file checksums** for key artifacts.

**Why it matters**: Catches subtle packaging mistakes that pass basic tar checks.

---

### 7) Build `manifest.json`

Include (example fields):

```json
{
  "artifact": "parakeet-rnnt-1.1b-en-us",
  "version": "v8.1",
  "source": "MODEL_PRIMARY_URL",
  "sha256_archive": "…",
  "files": [{"path":"model/…","size":12345,"sha256":"…"}],
  "created_at": "2025-09-27T20:00:00Z",
  "s3_prefix": "s3://…/parakeet-rnnt-1.1b-en-us/v8.1/"
}
```

**Why it matters**: Downstream scripts can trust & verify exactly what was staged.

---

### 8) Upload to S3 (atomic as possible)

* Prefer `aws s3 cp/sync` **with**:

  * `--sse AES256` or `--sse-kms --sse-kms-key-id "$KMS_KEY_ID"` (if set)
  * `--storage-class "$STORAGE_CLASS"` (if set)
  * `--only-show-errors` in CI logs
* Upload order: `archive/` → `model/` → `checksums/` → `manifest.json` → **`READY.ok` last**.
* Apply object **tags** if `$UPLOAD_TAGS` is set.

**Why it matters**: The presence of `READY.ok` signals a complete, validated drop.

---

### 9) Post-upload verification

* `aws s3 ls` and (optionally) download a few random objects to verify integrity.
* (Optional) compare **S3 object ETags** vs local MD5 for smaller files.

**Why it matters**: Read-after-write sanity prevents half-published states.

---

### 10) Cleanup & exit codes

* On success: remove temp dirs; keep logs.
* On failure: leave work dir + logs intact, return non-zero.
* Print **next steps** (e.g., “Run `riva-140-…` to deploy from S3”).

**Why it matters**: Make both success and failure actionable.

---

## S3 layout (example)

```
s3://$S3_STAGING_BUCKET/$S3_STAGING_PREFIX/$ARTIFACT_NAME/$VERSION/
  ├─ archive/
  │   └─ parakeet-rnnt-riva-1-1b-en-us-deployable_v8.1.tar.gz
  ├─ model/
  │   ├─ triton/...
  │   └─ riva/...
  ├─ checksums/
  │   ├─ archive.sha256
  │   └─ tree.sha256
  ├─ manifest.json
  └─ READY.ok
```

---

## Usage (typical)

```bash
# Dry run to preview:
DRY_RUN=1 ./scripts/riva-130-downloads-validates-and-stages-model-artifacts-to-s3.sh

# Real run:
./scripts/riva-130-downloads-validates-and-stages-model-artifacts-to-s3.sh
```

* Set/override env vars in `.env`; never hardcode in the script.
* Use `FORCE=1` to overwrite an existing version (discouraged in prod).

---

## Observability

* All actions streamed to `logs/riva-130/<timestamp>.log` and console.
* Key decisions (URLs, S3 dest, hashes) are echoed and included in the manifest.

---

## Common failure modes & fixes

* **Checksum mismatch** → Source file rotated/corrupt; update `$MODEL_SHA256` only if you have a verified, trusted new hash.
* **S3 access denied** → Recheck IAM and bucket policy (PutObject + KMS if used).
* **Archive structure unexpected** → Upstream packaging change; pin URL/version explicitly, update structural checks.
* **Out of disk** → Clear `artifacts/` or set a larger workspace volume.

---

## Downstream next steps

* Run the **deploy** script that consumes this S3 prefix (e.g., `riva-140-…`) on your GPU instance(s).
* Then run **smoke tests** to confirm model load & inference health (e.g., `riva-150-…`). ([GitHub][1])

