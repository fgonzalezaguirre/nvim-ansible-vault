NVIM ?= nvim

.PHONY: test format lint

test:
	$(NVIM) --headless -l tests/run.lua

format:
	stylua .

lint:
	stylua --check .
