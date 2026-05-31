BRANCH ?= fw-cicd-demo

.PHONY: load-base load-schema load-data verify

load-base:
	uv run infrahubctl schema load schemas/base/location.yml schemas/base/ipam.yml schemas/base/dcim.yml \
		--branch $(BRANCH) --wait 30

load-schema: load-base
	uv run infrahubctl schema load schemas/security.yml --branch $(BRANCH) --wait 30

load-data:
	uv run infrahubctl object load data/00-zones.yml data/10-addresses.yml data/20-services.yml \
		data/30-policy.yml data/40-rules.yml data/50-firewall.yml --branch $(BRANCH)

verify:
	INFRAHUB_BRANCH=$(BRANCH) uv run python verify.py
