KVER ?= 6.12.20

.PHONY: all test
all: test

test:
	command -v vng >/dev/null
	KVER=$(KVER) ./run.sh
