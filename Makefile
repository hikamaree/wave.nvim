NVIM ?= nvim
HEADLESS := $(NVIM) --headless -u NONE -l

# Neovim embeds LuaJIT, which is Lua 5.1 plus extensions. Run the pure tests
# on the same interpreter the plugin actually runs on, so 5.2+ syntax cannot
# pass locally and then fail elsewhere.
LUA ?= $(shell command -v luajit 2>/dev/null || command -v lua5.1 2>/dev/null || echo lua)

.PHONY: all build test syntax test-model test-render test-ipc test-integration test-netlist test-app test-mouse golden golden-update purity lint clean

all: build test

build:
	cd cmd && cargo build --release

test: syntax test-model test-render test-ipc test-integration test-netlist test-app test-mouse golden

# The model layer is pure, so it runs without Neovim.
test-model:
	@echo "== model =="
	@$(LUA) tests/test_model.lua

test-render:
	@echo "== render =="
	@$(HEADLESS) tests/test_render.lua

test-ipc:
	@echo "== ipc =="
	@$(HEADLESS) tests/test_ipc.lua

test-integration:
	@echo "== integration =="
	@$(HEADLESS) tests/test_viewer_integration.lua

test-netlist:
	@echo "== netlist =="
	@$(HEADLESS) tests/test_netlist.lua

test-app:
	@echo "== app =="
	@$(HEADLESS) tests/test_app.lua

# Mouse events need a running event loop, so this one cannot use -l.
test-mouse:
	@echo "== mouse =="
	@$(NVIM) --headless -u tests/test_mouse.lua < /dev/null

golden:
	@echo "== golden =="
	@$(HEADLESS) tests/golden.lua

golden-update:
	@$(HEADLESS) tests/golden.lua update

# model/ and render/ stay free of the Neovim API, dependencies point one way,
# and nothing forms a cycle.
purity:
	@echo "== layers =="
	@$(LUA) tests/check_layers.lua
	@echo "== purity =="
	@hits=$$(grep -rnE "vim\.(api|fn|uv|bo|wo|o)\b" lua/wave/model lua/wave/render 2>/dev/null \
		| grep -vE "^[^:]+:[0-9]+:[[:space:]]*--" || true); \
	if [ -n "$$hits" ]; then echo "FAIL: vim API used in a pure layer"; echo "$$hits"; exit 1; fi
	@echo "  OK: model/ and render/ are free of the Neovim API"

# Parses every file on the target runtime, including the ones no test imports
# (plugin/, and any module not yet required from a test).
syntax:
	@echo "== syntax =="
	@fail=0; for f in $$(find lua plugin tests -name '*.lua'); do \
		$(LUA) -e "assert(loadfile('$$f'))" 2>&1 | grep . && { echo "  FAIL: $$f"; fail=1; }; \
	done; \
	if [ $$fail -ne 0 ]; then exit 1; fi; \
	echo "  OK: $$(find lua plugin tests -name '*.lua' | wc -l | tr -d ' ') files parse"

lint:
	@command -v luacheck >/dev/null && luacheck lua/ plugin/ || echo "luacheck not installed, skipping"
	@command -v stylua  >/dev/null && stylua --check lua/ plugin/ || echo "stylua not installed, skipping"

clean:
	cd cmd && cargo clean
