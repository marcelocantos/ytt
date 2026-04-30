bullseye:
	@python3 -m py_compile ytt.py && echo "✓ syntax (ytt.py)"
	@bash -n scripts/playlist-ingest/ingest.sh && echo "✓ syntax (ingest.sh)"
	@bash -n scripts/playlist-ingest/ingest-one.sh && echo "✓ syntax (ingest-one.sh)"
	@bash -n scripts/playlist-ingest/build-index.sh && echo "✓ syntax (build-index.sh)"
	@test -z "$$(git status --porcelain)" && echo "✓ clean tree" || \
		(echo "✗ dirty tree"; git status --short; exit 1)

.PHONY: bullseye
