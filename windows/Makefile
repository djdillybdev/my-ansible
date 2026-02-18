.PHONY: lint syntax check doctor

lint:
	ansible-lint playbook.yml

syntax:
	ANSIBLE_LOCAL_TEMP=/tmp/ansible-local ansible-playbook -i inventory.ini --syntax-check playbook.yml

check: syntax
	@if command -v ansible-lint >/dev/null 2>&1; then \
		ansible-lint playbook.yml; \
	else \
		echo "ansible-lint not installed; skipping lint"; \
	fi

doctor:
	./scripts/doctor.sh
