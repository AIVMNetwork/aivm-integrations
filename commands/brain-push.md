---
description: Upload a local folder of notes/docs into the governed AIVM brain (searchable immediately).
argument-hint: [folder path, e.g. ./_brain or ./docs]
---

Upload the files in `$ARGUMENTS` (default `./_brain` if empty) into the governed brain using the aivm-brain upload tool — one call per file, with a title and the right knowledge domain. Each file is DLP-scanned, ACL-assigned, versioned, recorded, and immediately searchable. Report how many landed, and any that were blocked (e.g. a secret caught at the door) and why.
