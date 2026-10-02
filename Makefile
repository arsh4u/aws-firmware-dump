SHELL := /usr/bin/env bash
TF    := terraform -chdir=terraform
JOBS  ?= 1

.PHONY: help init fmt validate plan apply configure probe dump dump-batch watch ls pull unpack list cleanup destroy check

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	 | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

init:            ## terraform init
	$(TF) init -upgrade

fmt:             ## terraform fmt
	$(TF) fmt -recursive

validate:        ## terraform validate (requires init)
	$(TF) validate

plan:            ## terraform plan
	$(TF) plan

apply:           ## create bucket + IAM + VPC (no billable compute)
	$(TF) apply

configure:       ## export terraform outputs into .env / .azs
	scripts/configure.sh

probe:           ## free launch check: make probe AMI=ami-...
	scripts/probe.sh --ami "$(AMI)" $(if $(BOOT),--boot-type $(BOOT),)

dump:            ## acquire one AMI: make dump LABEL=name AMI=ami-...
	scripts/dump.sh --label "$(LABEL)" --ami "$(AMI)" $(if $(BOOT),--boot-type $(BOOT),) $(if $(DWELL),--dwell $(DWELL),)

dump-batch:      ## acquire a batch file: make dump-batch BATCH=images.tsv JOBS=4
	scripts/dump.sh --batch "$(BATCH)" --jobs $(JOBS)

watch:           ## live progress of in-flight acquisitions
	scripts/watch.sh --interval $(or $(INTERVAL),15)

ls:              ## show the S3 golden store + manifest summary
	scripts/ls.sh $(if $(LOCAL),--local,)

pull:            ## copy images out of S3: make pull LABELS="a b" [RAW=1]
	scripts/pull.sh $(if $(RAW),--raw,) $(LABELS)

unpack:          ## materialise sparse raw images: make unpack LABEL=...
	scripts/unpack.sh "$(LABEL)"

list:            ## show billable resources tagged by this stack
	scripts/cleanup.sh --list

cleanup:         ## terminate helpers, drop volumes/snapshots, empty staging
	scripts/cleanup.sh --all $(if $(FORCE),--force,)

destroy:         ## terraform destroy (bucket has force_destroy = true)
	$(TF) destroy

check:           ## syntax-check scripts (no AWS calls)
	@bash -n scripts/*.sh
	@python3 -m py_compile scripts/ebs_snapshot_read.py
	@echo "ok"
