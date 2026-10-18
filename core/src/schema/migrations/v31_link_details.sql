-- v31_link_details: what a task's links are, beyond the address. The
-- addresses stay in `externalLinksJSON`, which every client already reads
-- and opens; this holds a JSON object keyed by address of what the link
-- picker knew when the link was made: the file's name and its type
-- (`{"https://docs.google.com/...": {"title": "Budget", "mimeType": "..."}}`).
-- NULL is nothing known, which is every link before. See docs/links.md.
-- Written for the Rust core; the journal and outbox triggers are reinstalled after it.
ALTER TABLE "task_metadata" ADD COLUMN "linkDetailsJSON" TEXT;
