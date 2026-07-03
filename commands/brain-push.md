---
description: Upload a local folder of notes/docs into the governed AIVM brain (searchable immediately).
argument-hint: [folder path, e.g. ./_brain or ./docs]
---

Upload the files in `$ARGUMENTS` (default `./_brain` if empty) into the governed brain. For more than a couple of files, use the **brain_upload_batch** tool — one request carrying up to 100 docs (title + right knowledge domain + content each) instead of a call per file; it's one round-trip, won't overload the brain, and returns per-document results. For a single file, brain_upload is fine. Each file is DLP-scanned, ACL-assigned, versioned, recorded, and immediately searchable. If you fall back to single brain_upload calls, upload sequentially (not a parallel burst) and retry a file on 502/503. With brain_upload_batch this is handled for you — split into 100-doc batches for very large folders. Report how many landed, and any that were blocked (e.g. a secret caught at the door) and why.
