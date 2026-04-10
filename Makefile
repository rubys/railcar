PRISM_GEM := $(shell ruby -e "puts Gem::Specification.find_by_name('prism').gem_dir" 2>/dev/null)
BUILD_DIR := build
LIB_DIR := $(BUILD_DIR)/lib
BLOG_URL := https://ruby2js.github.io/ruby2js/releases/demo-blog.tar.gz

all: $(BUILD_DIR)/railcar

$(LIB_DIR)/libprism.a:
	@if [ -z "$(PRISM_GEM)" ]; then echo "Error: prism gem not found. Install with: gem install prism"; exit 1; fi
	@mkdir -p $(LIB_DIR)
	cd $(PRISM_GEM) && make static
	cp $(PRISM_GEM)/build/libprism.a $(LIB_DIR)/

$(BUILD_DIR)/demo/blog/Gemfile:
	@mkdir -p $(BUILD_DIR)/demo
	curl -sL $(BLOG_URL) | tar xz -C $(BUILD_DIR)/demo

CRYSTAL_STDLIB := $(shell crystal env CRYSTAL_PATH | tr ':' '\n' | grep -v '^lib$$' | head -1)

$(BUILD_DIR)/railcar: $(LIB_DIR)/libprism.a $(shell find src -name '*.cr' 2>/dev/null)
	CRYSTAL_CONFIG_PATH="lib:$(CRYSTAL_STDLIB)" crystal build src/cli.cr -o $(BUILD_DIR)/railcar

test: $(LIB_DIR)/libprism.a $(BUILD_DIR)/demo/blog/Gemfile
	CRYSTAL_CONFIG_PATH="lib:$(CRYSTAL_STDLIB)" crystal spec

clean:
	rm -rf $(BUILD_DIR)

.PHONY: all test clean
