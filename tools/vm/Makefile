KVER ?= 6.12

.PHONY: all test
all: test

test:
	command -v vng >/dev/null
	vng -v -r v$(KVER) -- bundle exec rake test:system
