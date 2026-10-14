# Developer shortcuts. Nothing here touches ~/.ssh except `make e2e-container`,
# which runs inside a throwaway container.
SHELL_SCRIPTS := scripts/*.sh scripts/ssh-askpass scripts/ssh-find scripts/ssh-hosts \
                 scripts/ssh-manage scripts/ssh-menu scripts/ssh-tmux tests/*.sh

.PHONY: all lint test privacy e2e-container

all: lint privacy test

lint:
	shellcheck -S warning -x $(SHELL_SCRIPTS)
	python3 -c "import ast; ast.parse(open('scripts/ssh-pass').read())"

privacy:
	tests/check-no-private-data.sh

test:
	tests/smoke.sh

# The end-to-end test installs into ~/.ssh, so it only ever runs in a container.
e2e-container:
	docker run --rm -v "$(CURDIR):/src:ro" ubuntu:24.04 bash -c '\
	    apt-get update -qq && apt-get install -y -qq openssh-client bsdextrautils >/dev/null && \
	    cp -a /src /work && cd /work && SSH_FLEET_E2E=1 tests/e2e.sh'
