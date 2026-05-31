BRANCH ?= fw-cicd-demo

.PHONY: load-schema load-data verify

load-schema:
	uv run infrahubctl schema load schemas/security.yml --branch $(BRANCH) --wait 30

load-data:
	uv run infrahubctl object load data/00-zones.yml data/10-addresses.yml data/20-services.yml \
		data/30-policy.yml data/40-rules.yml data/50-firewall.yml --branch $(BRANCH)

verify:
	INFRAHUB_BRANCH=$(BRANCH) uv run python verify.py
