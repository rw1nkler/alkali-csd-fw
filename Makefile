# -----------------------------------------------------------------------------
# Common settings -------------------------------------------------------------
# -----------------------------------------------------------------------------

ROOT_DIR = $(realpath $(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
NVME_SPEC_NAME = NVM-Express-1_4-2019.06.10-Ratified.pdf
DOCKER_TAG_NAME=fw:1.0

# Input settings -------------------------------------------------------------

DOCKER_TAG ?= $(DOCKER_IMAGE_PREFIX)$(DOCKER_TAG_NAME)

BUILD_DIR ?= $(ROOT_DIR)/build
WEST_INIT_DIR ?= $(RPUAPP_DIR)

# Input paths ----------------------------------------------------------------

THIRD_PARTY_DIR = $(ROOT_DIR)/third-party
REGGEN_DIR = $(ROOT_DIR)/third-party/registers-generator
BUILDROOT_DIR = $(ROOT_DIR)/third-party/buildroot
SCRIPTS_DIR = $(ROOT_DIR)/scripts
RPUAPP_DIR = $(ROOT_DIR)/rpu-app
ZEPHYR_PATCHES_DIR=$(RPUAPP_DIR)/patches

# Output paths ----------------------------------------------------------------

APUAPP_BUILD_DIR = $(BUILD_DIR)/apu-app
RPUAPP_BUILD_DIR = $(BUILD_DIR)/rpu-app
BUILDROOT_BUILD_DIR = $(BUILD_DIR)/buildroot
DOCKER_BUILD_DIR = $(BUILD_DIR)/docker
ZEPHYR_DOWNLOAD_DIR = $(BUILD_DIR)/zephyr-sources

# Helpers  --------------------------------------------------------------------

NVME_SPEC_FILE = $(REGGEN_DIR)/$(NVME_SPEC_NAME)

# -----------------------------------------------------------------------------
# All -------------------------------------------------------------------------
# -----------------------------------------------------------------------------

.PHONY: all
all: buildroot apu-app rpu-app ## Build all binaries (Buildroot, APU App, RPU App)

# -----------------------------------------------------------------------------
# Clean -----------------------------------------------------------------------
# -----------------------------------------------------------------------------

.PHONY: clean
clean: ## Remove ALL build artifacts
	$(RM) -r $(BUILD_DIR)
	$(RM) -r $(WEST_DIR)

# -----------------------------------------------------------------------------
# Buildroot SDK ---------------------------------------------------------------
# -----------------------------------------------------------------------------

# NOTE: The targets related to building a complete rootfs are located
#       after those related to APU app, zephyr and RPU app

BR2_EXTERNAL_DIR = $(ROOT_DIR)/br2-external
BR2_EXTERNAL_OVERLAY_DIR = $(BR2_EXTERNAL_DIR)/board/alkali/overlay
BUILDROOT_BOARD_BUILD_DIR = $(BUILDROOT_BUILD_DIR)/board/alkali
BUILDROOT_BOARD_OVERLAY_BUILD_DIR = $(BUILDROOT_BOARD_BUILD_DIR)/overlay
BUILDROOT_OPTS = O=$(BUILDROOT_BUILD_DIR) -C $(BUILDROOT_DIR) BR2_EXTERNAL=$(BR2_EXTERNAL_DIR)
BUILDROOT_TOOLCHAIN_TAR_FILE = $(BUILDROOT_BUILD_DIR)/images/aarch64-buildroot-linux-gnu_sdk-buildroot.tar.gz
BUILDROOT_TOOLCHAIN_OUTPUT_DIR = $(BUILD_DIR)/aarch64-buildroot-linux-gnu_sdk-buildroot
BUILDROOT_TOOLCHAIN_CMAKE_FILE = $(BUILDROOT_TOOLCHAIN_OUTPUT_DIR)/share/buildroot/toolchainfile.cmake
BUILDROOT_IMAGES_DIR = $(BUILDROOT_BUILD_DIR)/images
BUILDROOT_OUTPUTS := \
	$(BUILDROOT_IMAGES_DIR)/bl31.elf \
	$(BUILDROOT_IMAGES_DIR)/Image \
	$(BUILDROOT_IMAGES_DIR)/rootfs.cpio.uboot \
	$(BUILDROOT_IMAGES_DIR)/u-boot.elf \
	$(BUILDROOT_IMAGES_DIR)/zynqmp-an300-nvme.dtb \
	$(BUILDROOT_IMAGES_DIR)/zynqmp-zcu106-nvme.dtb

$(BUILDROOT_BOARD_OVERLAY_BUILD_DIR):
	mkdir -p $@

.PHONY: buildroot/sdk
buildroot/sdk: $(BUILDROOT_TOOLCHAIN_TAR_FILE) ## Generate Buildroot toolchain

.PHONY: buildroot/sdk-untar
buildroot/sdk-untar: $(BUILDROOT_TOOLCHAIN_CMAKE_FILE) ## Untar Buildroot toolchain (helper)

$(BUILDROOT_TOOLCHAIN_CMAKE_FILE): $(BUILDROOT_TOOLCHAIN_TAR_FILE)
	tar mxf $(BUILDROOT_TOOLCHAIN_TAR_FILE) -C $(BUILD_DIR)

$(BUILDROOT_TOOLCHAIN_TAR_FILE): | $(BUILDROOT_BOARD_OVERLAY_BUILD_DIR)
	$(MAKE) $(BUILDROOT_OPTS) zynqmp_nvme_defconfig
	$(MAKE) $(BUILDROOT_OPTS) sdk

# -----------------------------------------------------------------------------
# APU App ---------------------------------------------------------------------
# -----------------------------------------------------------------------------

APUAPP_DIR = $(ROOT_DIR)/apu-app
APUAPP_SRC_DIR = $(ROOT_DIR)/apu-app/src
APUAPP_INSTALL_DIR = $(BUILD_DIR)/apu-app/install
APUAPP_BUILD_TYPE ?= Debug
APUAPP_OUTPUTS = $(APUAPP_BUILD_DIR)/libvta-delegate.so $(APUAPP_BUILD_DIR)/apu-app $(APUAPP_BUILD_DIR)/tflite-delegate-test
APUAPP_SOURCES = \
	$(wildcard $(APUAPP_SRC_DIR)/*.cpp) \
	$(wildcard $(APUAPP_SRC_DIR)/*.hpp) \
	$(wildcard $(APUAPP_SRC_DIR)/*.h) \
	$(wildcard $(APUAPP_SRC_DIR)/vm/*.cpp) \
	$(wildcard $(APUAPP_SRC_DIR)/cmd/*.cpp) \
	$(wildcard $(APUAPP_SRC_DIR)/vta/*.cc) \
	$(wildcard $(APUAPP_SRC_DIR)/vta/*.cpp) \
	$(wildcard $(APUAPP_SRC_DIR)/vta/*.h) \
	$(wildcard $(APUAPP_SRC_DIR)/vta/*.hpp)

.PHONY: apu-app
apu-app: $(APUAPP_OUTPUTS) ## Build APU App

.PHONY: apu-app/clean
apu-app/clean: ## Remove APU App build files
	$(RM) -r $(APUAPP_BUILD_DIR)

$(APUAPP_OUTPUTS) &: $(BUILDROOT_TOOLCHAIN_CMAKE_FILE) $(APUAPP_SOURCES)
	@mkdir -p $(APUAPP_BUILD_DIR)
	cmake \
	      -DCMAKE_TOOLCHAIN_FILE=$(BUILDROOT_TOOLCHAIN_CMAKE_FILE) \
	      -DCMAKE_INSTALL_PREFIX=$(APUAPP_INSTALL_DIR) \
	      -DCMAKE_EXPORT_COMPILE_COMMANDS=1 \
	      -DUBPF_ENABLE_INSTALL=ON \
	      -DCMAKE_BUILD_TYPE=$(APUAPP_BUILD_TYPE) \
	      -DNO_HARDWARE=OFF \
	      -DBUILD_TESTS=ON \
	      -S $(APUAPP_DIR) -B $(APUAPP_BUILD_DIR)
	$(MAKE) -C $(APUAPP_BUILD_DIR) -j`nproc` all

# -----------------------------------------------------------------------------
# Zephyr ----------------------------------------------------------------------
# -----------------------------------------------------------------------------

WEST_DIR = $(ROOT_DIR)/.west
WEST_CONFIG ?= $(WEST_DIR)/config
WEST_YML ?= $(RPUAPP_DIR)/west.yml
ZEPHYR_SDK_VERSION = 0.10.3
ZEPHYR_SDK_NAME = zephyr-sdk-$(ZEPHYR_SDK_VERSION)
ZEPHYR_SDK_DOWNLOAD_URL = https://github.com/zephyrproject-rtos/sdk-ng/releases/download/v$(ZEPHYR_SDK_VERSION)/$(ZEPHYR_SDK_NAME)-setup.run
ZEPHYR_SDK_DOWNLOAD_PATH = $(BUILD_DIR)/zephyr-sdk.run
ZEPHYR_SDK_LOCAL_INSTALL_DIR = $(BUILD_DIR)/$(ZEPHYR_SDK_NAME)

ZEPHYR_SOURCES= \
	$(ZEPHYR_DOWNLOAD_DIR)/zephyr \
	$(ZEPHYR_DOWNLOAD_DIR)/tools \
	$(ZEPHYR_DOWNLOAD_DIR)/modules/hal/libmetal \
	$(ZEPHYR_DOWNLOAD_DIR)/modules \
	$(ZEPHYR_DOWNLOAD_DIR)/modules/hal/atmel \
	$(ZEPHYR_DOWNLOAD_DIR)/modules/lib/civetweb \
	$(ZEPHYR_DOWNLOAD_DIR)/modules/hal/esp-idf \
	$(ZEPHYR_DOWNLOAD_DIR)/modules/fs/fatfs \
	$(ZEPHYR_DOWNLOAD_DIR)/modules/hal/cypress \
	$(ZEPHYR_DOWNLOAD_DIR)/modules/hal/nordic \
	$(ZEPHYR_DOWNLOAD_DIR)/modules/hal/openisa \
	$(ZEPHYR_DOWNLOAD_DIR)/modules/hal/microchip \
	$(ZEPHYR_DOWNLOAD_DIR)/modules/hal/silabs \
	$(ZEPHYR_DOWNLOAD_DIR)/modules/hal/st \
	$(ZEPHYR_DOWNLOAD_DIR)/modules/hal/stm32 \
	$(ZEPHYR_DOWNLOAD_DIR)/modules/hal/ti \
	$(ZEPHYR_DOWNLOAD_DIR)/modules/lib/gui/lvgl \
	$(ZEPHYR_DOWNLOAD_DIR)/modules/crypto/mbedtls \
	$(ZEPHYR_DOWNLOAD_DIR)/modules/lib/mcumgr \
	$(ZEPHYR_DOWNLOAD_DIR)/modules/fs/nffs \
	$(ZEPHYR_DOWNLOAD_DIR)/modules/hal/nxp \
	$(ZEPHYR_DOWNLOAD_DIR)/modules/lib/open-amp \
	$(ZEPHYR_DOWNLOAD_DIR)/modules/lib/openthread \
	$(ZEPHYR_DOWNLOAD_DIR)/modules/debug/segger \
	$(ZEPHYR_DOWNLOAD_DIR)/modules/lib/tinycbor \
	$(ZEPHYR_DOWNLOAD_DIR)/modules/fs/littlefs \
	$(ZEPHYR_DOWNLOAD_DIR)/modules/debug/mipi-sys-t

.PHONY: zephyr/sdk
zephyr/sdk: $(ZEPHYR_SDK_LOCAL_INSTALL_DIR) ## Install Zephyr SDK locally (helper)
	@echo "To use local installation of the toolchain set the following environment variables:"
	@echo "  - ZEPHYR_TOOLCHAIN_VARIANT=zephyr"
	@echo "  - ZEPHYR_SDK_INSTALL_DIR=$(ZEPHYR_SDK_LOCAL_INSTALL_DIR)"

.PHONY: zephyr/setup
zephyr/setup: $(WEST_YML) ## Install Zephyr dependencies and get Zephyr sources
zephyr/setup: $(ZEPHYR_SOURCES)

.PHONY: zephyr/clean
zephyr/clean: ## Remove Zephyr installed files
	$(RM) -r $(BUILD_DIR)/zephyr*
	$(RM) -r $(WEST_DIR)

$(ZEPHYR_SDK_DOWNLOAD_PATH):
	@mkdir -p $(BUILD_DIR)
	wget -q $(ZEPHYR_SDK_DOWNLOAD_URL) -O $(ZEPHYR_SDK_DOWNLOAD_PATH)

$(ZEPHYR_SDK_LOCAL_INSTALL_DIR): $(ZEPHYR_SDK_DOWNLOAD_PATH)
	chmod u+rwx $(ZEPHYR_SDK_DOWNLOAD_PATH)
	bash $(ZEPHYR_SDK_DOWNLOAD_PATH) --quiet -- -d $(ZEPHYR_SDK_LOCAL_INSTALL_DIR)

$(ZEPHYR_SOURCES) &: $(SCRIPTS_DIR)/copy_and_patch.py $(ZEPHYR_PATCHES_DIR)/zephyr $(ZEPHYR_PATCHES_DIR)/libmetal | $(WEST_CONFIG)
	$(RM) -r $(BUILD_DIR)/zephyr $(BUILD_DIR)/libmetal
	west update
	$(SCRIPTS_DIR)/copy_and_patch.py -f $(ZEPHYR_DOWNLOAD_DIR)/zephyr $(ZEPHYR_DOWNLOAD_DIR)/zephyr -p $(ZEPHYR_PATCHES_DIR)/zephyr
	$(SCRIPTS_DIR)/copy_and_patch.py -f $(ZEPHYR_DOWNLOAD_DIR)/modules/hal/libmetal $(ZEPHYR_DOWNLOAD_DIR)/modules/hal/libmetal -p $(ZEPHYR_PATCHES_DIR)/libmetal

$(WEST_CONFIG): SHELL := /bin/bash
$(WEST_CONFIG):
	@echo "Initialize west for Zephyr."; \
	if west init -l --mf $(WEST_YML) $(WEST_INIT_DIR); then \
		echo "Done."; \
	else \
		echo ""; \
		echo -e "\e[31mError:\e[0m West initialization failed. It might be caused by another west config instance"; \
		echo -e "\e[31mError:\e[0m in a parent directory. Remove an existing '.west' and try again."; \
		echo -e "\e[31mError:\e[0m "; \
		echo -e "\e[31mError:\e[0m If you want to have west initialized in multiple directories of one tree you must"; \
		echo -e "\e[31mError:\e[0m first initialize it in a directory that is lower in hierarchy."; \
		echo ""; \
		exit -1; \
	fi;

# -----------------------------------------------------------------------------
# RPU App ---------------------------------------------------------------------
# -----------------------------------------------------------------------------

RPUAPP_SRC_DIR = $(RPUAPP_DIR)/src
RPUAPP_GENERATED_DIR = $(RPUAPP_BUILD_DIR)/generated
RPUAPP_ZEPHYR_ELF = $(RPUAPP_BUILD_DIR)/zephyr/zephyr.elf
RPUAPP_SOURCES = \
	$(wildcard $(RPUAPP_SRC_DIR)/*.c) \
	$(wildcard $(RPUAPP_SRC_DIR)/*.h) \
	$(wildcard $(RPUAPP_SRC_DIR)/cmds/*.h) \
	$(wildcard $(RPUAPP_SRC_DIR)/cmds/*.c)

IN_ZEPHYR_ENV = source $(ZEPHYR_DOWNLOAD_DIR)/zephyr/zephyr-env.sh
IN_SDK_ENV = \
	source $(BUILD_DIR)/zephyr/zephyr-env.sh && \
	export ZEPHYR_TOOLCHAIN_VARIANT=zephyr && \
	export ZEPHYR_SDK_INSTALL_DIR=$(ZEPHYR_SDK_LOCAL_INSTALL_DIR)

CMAKE_OPTS = -DGENERATED_DIR=$(RPUAPP_GENERATED_DIR) -DREGGEN_DIR=$(REGGEN_DIR) \
	-DNVME_SPEC_FILE=$(NVME_SPEC_FILE) -DRPUAPP_GENERATED_DIR=$(RPUAPP_GENERATED_DIR)
WEST_BUILD = west build -b zcu106 -d $(RPUAPP_BUILD_DIR) rpu-app $(CMAKE_OPTS)

.PHONY: rpu-app
rpu-app: $(RPUAPP_ZEPHYR_ELF) ## Build RPU App

.PHONY: rpu-app/with-sdk
rpu-app/with-sdk: SHELL:=/bin/bash ## Build RPU App with local Zephyr SDK (helper)
rpu-app/with-sdk: zephyr/sdk zephyr/setup
	$(IN_SDK_ENV) && $(WEST_BUILD)

.PHONY: rpu-app/clean
rpu-app/clean: ## Remove RPU App build files
	$(RM) -r $(RPUAPP_BUILD_DIR)

$(RPUAPP_ZEPHYR_ELF): SHELL := /bin/bash
$(RPUAPP_ZEPHYR_ELF): $(ZEPHYR_SOURCES)
$(RPUAPP_ZEPHYR_ELF): $(RPUAPP_SOURCES)
	$(IN_ZEPHYR_ENV) && $(WEST_BUILD)

# -----------------------------------------------------------------------------
# Buildroot -------------------------------------------------------------------
# -----------------------------------------------------------------------------
#
# NOTE: The targets related to building a Buildroot SDK together with all the
#       configuration variables are located above, after all and clean targets.

.PHONY: buildroot
buildroot: $(BUILDROOT_OUTPUTS) ## Build Buildroot

$(BUILDROOT_OUTPUTS) &: $(APUAPP_OUTPUTS) $(RPUAPP_ZEPHYR_ELF) ## Build Buildroot
	cp -r $(BR2_EXTERNAL_OVERLAY_DIR) $(BUILDROOT_BOARD_BUILD_DIR)
	mkdir -p $(BUILDROOT_BOARD_OVERLAY_BUILD_DIR)/lib/firmware
	cp $(APUAPP_BUILD_DIR)/*.so $(BUILDROOT_BOARD_OVERLAY_BUILD_DIR)/lib/.
	cp $(RPUAPP_ZEPHYR_ELF) $(BUILDROOT_BOARD_OVERLAY_BUILD_DIR)/lib/firmware/zephyr.elf
	mkdir -p $(BUILDROOT_BOARD_OVERLAY_BUILD_DIR)/bin
	cp $(APUAPP_BUILD_DIR)/apu-app $(BUILDROOT_BOARD_OVERLAY_BUILD_DIR)/bin/.
	cp $(APUAPP_BUILD_DIR)/tflite-delegate-test $(BUILDROOT_BOARD_OVERLAY_BUILD_DIR)/bin/.
	$(MAKE) $(BUILDROOT_OPTS) zynqmp_nvme_defconfig
	$(MAKE) $(BUILDROOT_OPTS) -j`nproc`
	touch -c $(BUILDROOT_OUTPUTS)

.PHONY: buildroot/distclean
buildroot/distclean: ## Remove Buildroot build
	$(MAKE) $(BUILDROOT_OPTS) distclean

.PHONY: buildroot//%
buildroot//%: ## Forward rule to invoke Buildroot rules directly e.g. `make buildroot//menuconfig`
	$(MAKE) $(BUILDROOT_OPTS) $*

# -----------------------------------------------------------------------------
# Docker ----------------------------------------------------------------------
# -----------------------------------------------------------------------------

REGGEN_REL_DIR=$(shell realpath --relative-to $(ROOT_DIR) $(REGGEN_DIR))
DOCKER_BUILD_PYTHON_REQS_DIR=$(DOCKER_BUILD_DIR)/$(REGGEN_REL_DIR)


$(DOCKER_BUILD_DIR):
	@mkdir -p $(DOCKER_BUILD_DIR)

.PHONY: docker
docker: fw.dockerfile ## Build the development docker image
docker: requirements.txt
docker: $(REGGEN_DIR)/requirements.txt
docker: | $(DOCKER_BUILD_DIR)
	cp $(ROOT_DIR)/fw.dockerfile $(DOCKER_BUILD_DIR)/Dockerfile
	cp $(ROOT_DIR)/requirements.txt $(DOCKER_BUILD_DIR)/requirements.txt
	mkdir -p $(DOCKER_BUILD_PYTHON_REQS_DIR)
	cp $(REGGEN_DIR)/requirements.txt $(DOCKER_BUILD_PYTHON_REQS_DIR)/requirements.txt
	cd $(DOCKER_BUILD_DIR) && docker build \
		$(DOCKER_BUILD_EXTRA_ARGS) \
		-t $(DOCKER_TAG) .

.PHONY: docker/clean
docker/clean:
	$(RM) -r $(DOCKER_BUILD_DIR)

# -----------------------------------------------------------------------------
# Enter -----------------------------------------------------------------------
# -----------------------------------------------------------------------------

.PHONY: enter
enter: ## enter the development docker image
	docker run \
		--rm \
		-v $(PWD):$(PWD) \
		-v /etc/passwd:/etc/passwd \
		-v /etc/group:/etc/group \
		-e CCACHE_DISABLE=1 \
		-u $(shell id -u):$(shell id -g) \
		-h docker-container \
		-w $(PWD) \
		-it \
		$(DOCKER_RUN_EXTRA_ARGS) \
		$(DOCKER_TAG)

# -----------------------------------------------------------------------------
# Help ------------------------------------------------------------------------
# -----------------------------------------------------------------------------

HELP_COLUMN_SPAN = 25
HELP_FORMAT_STRING = "\033[36m%-$(HELP_COLUMN_SPAN)s\033[0m %s \033[34m%s\033[0m\n"
USED_IN_BUILD_MESSAGE = (used to configure build inside 'alkali-csd-build')
.PHONY: help
help: ## Show this help message
	@echo Here is the list of available targets:
	@echo ""
	@grep -E '^[^#[:blank:]]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf $(HELP_FORMAT_STRING), $$1, $$2, ""}'
	@echo ""
	@echo "Additionally, you can use the following environment variables:"
	@echo ""
	@printf $(HELP_FORMAT_STRING) "DOCKER_RUN_EXTRA_ARGS" "Extra arguments to pass to container on 'make enter'" " "
	@printf $(HELP_FORMAT_STRING) "DOCKER_IMAGE_PREFIX" "Registry prefix with '/' at the end" " "
	@printf $(HELP_FORMAT_STRING) "DOCKER_TAG" "Docker tag for building and running images" " "
	@printf $(HELP_FORMAT_STRING) "DOCKER_RUN_EXTRA_ARGS" "Extra arguments for running docker container"
	@printf $(HELP_FORMAT_STRING) "DOCKER_BUILD_EXTRA_ARGS" "Extra arguments for building docker"
	@printf $(HELP_FORMAT_STRING) "BUILD_DIR" "Absolute path to desired build directory" "$(USED_IN_BUILD_MESSAGE)"
	@printf $(HELP_FORMAT_STRING) "APUAPP_BUILD_TYPE" "APU application build type, Debug (default) or Release" "$(USED_IN_BUILD_MESSAGE)"
	@printf $(HELP_FORMAT_STRING) "WEST_INIT_DIR" "Relative path to directory where west should be initialized" "$(USED_IN_BUILD_MESSAGE)"
	@printf $(HELP_FORMAT_STRING) "WEST_CONFIG" "Absolute path to '.west/config' configuration file" "$(USED_IN_BUILD_MESSAGE)"
	@printf $(HELP_FORMAT_STRING) "WEST_YML" "Absolute path to 'west.yml' manifest file" "$(USED_IN_BUILD_MESSAGE)"
	@echo ""

.DEFAULT_GOAL := help
