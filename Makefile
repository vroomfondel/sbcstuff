.PHONY: tests help install venv lint isort tcheck build commit-checks prepare gitleaks pypibuild pypipush docker update-all-dockerhub-readmes teflon-fetch teflon-release
SHELL := /usr/bin/bash
.ONESHELL:


help:
	@printf "\ninstall\n\tinstall requirements\n"
	@printf "\nisort\n\tmake isort import corrections\n"
	@printf "\nlint\n\tmake linter check with black\n"
	@printf "\ntcheck\n\tmake static type checks with mypy\n"
	@printf "\nprepare\n\tLaunch tests and commit-checks\n"
	@printf "\ncommit-checks\n\trun pre-commit checks on all files\n"
	@printf "\nteflon-fetch\n\tFetch libteflon.so build artifacts from Rock 5B\n"
	@printf "\nteflon-release\n\tFetch artifacts + create GitHub Release\n"


# check for "CI" not in os.environ || "GITHUB_RUN_ID" not in os.environ
venv_activated=if [ -z $${VIRTUAL_ENV+x} ] && [ -z $${GITHUB_RUN_ID+x} ] ; then printf "activating venv...\n" ; source .venv/bin/activate ; else printf "venv already activated or GITHUB_RUN_ID=$${GITHUB_RUN_ID} is set\n"; fi

install: venv

venv: .venv/touchfile

.venv/touchfile: requirements.txt requirements-dev.txt requirements-build.txt
	@if [ -z "$${GITHUB_RUN_ID}" ]; then \
		test -d .venv || python3.14 -m venv .venv; \
		source .venv/bin/activate; \
		pip install -r requirements-build.txt; \
		pip install -e .; \
		touch .venv/touchfile; \
	else \
		echo "Skipping venv setup because GITHUB_RUN_ID is set"; \
	fi


tests: venv
	@$(venv_activated)
	pytest .

lint: venv
	@$(venv_activated)
	black -l 120 .

isort: venv
	@$(venv_activated)
	isort .

tcheck: venv
	@$(venv_activated)
	mypy .

gitleaks: venv .git/hooks/pre-commit
	@$(venv_activated)
	pre-commit run gitleaks --all-files

.git/hooks/pre-commit: venv
	@$(venv_activated)
	pre-commit install

commit-checks: .git/hooks/pre-commit
	@$(venv_activated)
	pre-commit run --all-files

prepare: tests commit-checks

ROCK5B_HOST ?= root@rock5b
TEFLON_REMOTE_DIST := /tmp/mesa-teflon-build/dist/
TEFLON_LOCAL_DIST := dist

teflon-fetch:
	mkdir -p $(TEFLON_LOCAL_DIST)
	rsync -av --progress $(ROCK5B_HOST):$(TEFLON_REMOTE_DIST) $(TEFLON_LOCAL_DIST)/

teflon-release: teflon-fetch
	./scripts/rock5b/release-mesa-teflon.sh $(TEFLON_LOCAL_DIST)

# VERSION := $(shell $(venv_activated) > /dev/null 2>&1 && hatch version 2>/dev/null || echo HATCH_NOT_FOUND)

