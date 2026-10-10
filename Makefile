TF_DIRS := modules/platform envs/dev envs/prod

.PHONY: fmt lint test moto mutate all

fmt:
	terraform fmt -recursive

lint: ## fmt, validate, tflint
	terraform fmt -check -recursive
	for d in $(TF_DIRS); do (cd $$d && terraform init -backend=false -input=false >/dev/null && terraform validate) || exit 1; done
	tflint --init
	for d in $(TF_DIRS); do tflint --chdir=$$d --config=$(CURDIR)/.tflint.hcl || exit 1; done

test: ## terraform test with mocked AWS: guardrails + dev/prod profiles
	cd modules/platform && terraform init -backend=false -input=false >/dev/null && terraform test

moto: ## plan both envs against Moto, checkov + platform checks, apply network, re-plan, destroy
	tests/moto/run.sh

mutate: ## break platform guarantees one by one; every break must be caught
	tests/mutate.sh

all: lint test moto
