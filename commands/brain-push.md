---
description: Push a local folder of notes/docs into the governed AIVM brain review queue.
argument-hint: [folder path, e.g. ./_brain or ./docs]
---

Push the folder `$ARGUMENTS` (default `./_brain` if empty) into the governed brain's review queue using the aivm-brain upload/push tools. Each file is DLP-scanned, access-set for its domain, versioned, and recorded before it lands. Report how many files were queued, any that were blocked and why, and the review link.
