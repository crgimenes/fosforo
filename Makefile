# fosforo: C core (vt, glyph, pty) and the Swift app on top of it.
CC ?= cc
LLVM ?= /opt/homebrew/opt/llvm/bin
FILO_TERM ?= ../filo-term
FILO ?= ../clang_filo
ROC ?= ../rocchetto

WARN = -Wall -Wextra -Werror -Wshadow -Wconversion -Wdouble-promotion -Wundef
INC = -Ivt -Iglyph -Ipty -Iconfig -I$(FILO_TERM)/src -I$(FILO)
FLAGS = -std=c11 $(WARN) $(INC)
VT_SRC = vt/vt.c vt/grid.c vt/input.c $(FILO_TERM)/src/utf8.c
FILO_SRC = $(addprefix $(FILO)/,filo.c filo_math.c filo_strings.c filo_libc.c filo_fmt.c)
C_SRC = $(VT_SRC) glyph/glyph.c pty/pty.c config/cfg.c $(FILO_SRC)
OWN_C = vt/vt.c vt/grid.c vt/input.c glyph/glyph.c pty/pty.c config/cfg.c
HDRS = $(wildcard vt/*.h glyph/*.h pty/*.h config/*.h) $(FILO_TERM)/src/utf8.h $(FILO_TERM)/src/width_table.h $(FILO)/filo.h
FMT_FILES = $(OWN_C) rochost/main.c rochost/host.c rochost/host.h vt/vt.h vt/grid.h glyph/glyph.h pty/pty.h config/cfg.h test/*.c tools/*.c bench/*.c fuzz/*.c
SAN = -O1 -g -fsanitize=address,undefined -fno-sanitize-recover=all
FUZZ_SECONDS ?= 60
TIDY_CHECKS = bugprone-*,cert-*,clang-analyzer-*,readability-*,-readability-identifier-length,-readability-function-cognitive-complexity,-readability-magic-numbers,-cert-err33-c,-readability-else-after-return,-readability-simplify-boolean-expr,-bugprone-easily-swappable-parameters,-clang-analyzer-optin.performance.Padding
LIB_OBJ = $(patsubst %.c,build/obj/%.o,$(notdir $(C_SRC)))
# must match platforms in swift/Package.swift
LIB_FLAGS = -O2 $(FLAGS) -mmacosx-version-min=14.0

.PHONY: release ios-sim ios-device xcframework roc-host all lib test bench fuzz fmt fmt-check tidy check qa clean swift-fmt swift-build swift-test app

all: build/vtdump lib roc-host

# The rocchetto host on a pty, for testing host.c on the Mac (the Mac app has no
# rocchetto: it is only a terminal). libroc.a brings its own Filo and filo-term,
# which must not meet the app's copies in one binary. The flags come from
# rocchetto itself (they shape struct roc).
roc-host:
	$(MAKE) -C $(ROC) lib
	@mkdir -p build
	$(CC) -O2 $(WARN) $$(cat $(ROC)/build/libroc.cflags) -o build/fosforo-roc rochost/main.c rochost/host.c \
		$(ROC)/build/libroc.a
	$(CC) -O1 -g $(WARN) -Irochost $$(cat $(ROC)/build/libroc.cflags) \
		-DROC_FIXTURES='"$(abspath $(ROC))/test/fixtures/utilities.txt"' \
		-DROC_COMMANDS='"$(abspath $(ROC))/commands/bin"' -o build/test_rochost \
		test/test_rochost.c rochost/host.c $(ROC)/build/libroc.a
	./build/test_rochost

# The C core for the Swift package, macOS + iOS + simulator slices. It only
# packages: the warning gates are make test, tidy and check.
xcframework:
	$(MAKE) -C $(ROC) lib
	ROC_FLAGS="$$(cat $(ROC)/build/libroc.cflags)" \
	ROC_SRC="$$($(MAKE) -s -C $(ROC) lib-sources) $(abspath rochost/host.c)" \
	tools/xcframework.sh $(CC) "-O2 -std=c11 $(INC)" -- $(OWN_C) $(FILO_TERM)/src/utf8.c $(FILO_SRC)

lib: build/libfosforo.a

build/obj/%.o: vt/%.c $(HDRS)
	@mkdir -p build/obj
	$(CC) $(LIB_FLAGS) -c -o $@ $<

build/obj/%.o: glyph/%.c $(HDRS)
	@mkdir -p build/obj
	$(CC) $(LIB_FLAGS) -c -o $@ $<

build/obj/%.o: pty/%.c $(HDRS)
	@mkdir -p build/obj
	$(CC) $(LIB_FLAGS) -c -o $@ $<

build/obj/%.o: config/%.c $(HDRS)
	@mkdir -p build/obj
	$(CC) $(LIB_FLAGS) -c -o $@ $<

# Filo is its own project with its own gate; built here as it is.
build/obj/%.o: $(FILO)/%.c $(HDRS)
	@mkdir -p build/obj
	$(CC) -O2 -std=c11 -I$(FILO) -mmacosx-version-min=14.0 -c -o $@ $<

build/obj/utf8.o: $(FILO_TERM)/src/utf8.c $(HDRS)
	@mkdir -p build/obj
	$(CC) $(LIB_FLAGS) -c -o $@ $<

build/libfosforo.a: $(LIB_OBJ)
	rm -f $@
	ar rcs $@ $(LIB_OBJ)

build/vtdump: tools/vtdump.c $(VT_SRC) $(HDRS)
	@mkdir -p build
	$(CC) -O2 $(FLAGS) -o $@ tools/vtdump.c $(VT_SRC)

test: $(C_SRC) $(HDRS) test/test_vt.c test/test_glyph.c test/test_pty.c test/test_cfg.c
	@mkdir -p build
	$(CC) $(SAN) $(FLAGS) -DVT_TESTING -o build/test_vt test/test_vt.c $(VT_SRC)
	$(CC) $(SAN) $(FLAGS) -o build/test_glyph test/test_glyph.c glyph/glyph.c
	$(CC) $(SAN) $(FLAGS) -o build/test_pty test/test_pty.c pty/pty.c
	$(CC) $(SAN) $(FLAGS) -o build/test_cfg test/test_cfg.c config/cfg.c $(FILO_SRC)
	./build/test_vt
	./build/test_glyph
	./build/test_pty
	./build/test_cfg

bench: bench/bench_vt.c $(VT_SRC) $(HDRS)
	@mkdir -p build
	$(CC) -O2 $(FLAGS) -o build/bench_vt bench/bench_vt.c $(VT_SRC)
	./build/bench_vt

fuzz: fuzz/fuzz_vt.c $(VT_SRC) $(HDRS)
	@mkdir -p build
	$(LLVM)/clang -std=c11 -g -O1 $(INC) \
		-fsanitize=fuzzer,address,undefined -o build/fuzz_vt fuzz/fuzz_vt.c $(VT_SRC)
	@mkdir -p build/fuzz_corpus
	./build/fuzz_vt -max_total_time=$(FUZZ_SECONDS) -timeout=10 -max_len=4096 -dict=fuzz/vt.dict \
		build/fuzz_corpus fuzz/seeds

fmt:
	$(LLVM)/clang-format -i $(FMT_FILES)

fmt-check:
	$(LLVM)/clang-format --dry-run --Werror $(FMT_FILES)

tidy:
	$(LLVM)/clang-tidy --quiet --warnings-as-errors='*' --checks='$(TIDY_CHECKS)' \
		$(OWN_C) tools/vtdump.c -- -std=c11 $(INC)

check:
	cppcheck --enable=warning,style,performance,portability --inline-suppr \
		--suppress=missingIncludeSystem --error-exitcode=1 $(INC) \
		$(OWN_C) tools/vtdump.c test/test_vt.c test/test_glyph.c test/test_pty.c test/test_cfg.c

# Swift: format checked, every warning an error, Swift 6 strict concurrency.
swift-fmt:
	swift format lint --strict --recursive swift/Sources swift/Tests swift/Package.swift

swift-build: xcframework
	cd swift && swift build -Xswiftc -warnings-as-errors

# Serial, as the Metal and CoreText tests want; and under a deadline, since
# a CoreText XPC that never answers would hold the gate forever (perl's
# alarm: macOS has no timeout(1)).
swift-test: xcframework roc-host
	cd swift && perl -e 'alarm shift; exec @ARGV' 1800 swift test --no-parallel

# The app icon at every size, from the kamon (tools/gen_icon.swift).
icons: build/icons/fosforo.icns
build/icons/fosforo.icns: tools/gen_icon.swift
	rm -rf build/icons
	mkdir -p build/icons
	swift tools/gen_icon.swift build/icons
	iconutil -c icns build/icons/fosforo.iconset -o build/icons/fosforo.icns

# Local bundle, ad-hoc signed; Developer ID signing belongs to release.sh.
app: xcframework icons
	cd swift && swift build -c release -Xswiftc -warnings-as-errors
	rm -rf build/fosforo.app
	mkdir -p build/fosforo.app/Contents/MacOS
	cp swift/.build/release/fosforo build/fosforo.app/Contents/MacOS/fosforo
	cp assets/Info.plist build/fosforo.app/Contents/Info.plist
	mkdir -p build/fosforo.app/Contents/Resources
	cp assets/banner.ans build/icons/fosforo.icns build/fosforo.app/Contents/Resources/
	cp assets/PrivacyInfo.xcprivacy build/fosforo.app/Contents/Resources/
	plutil -lint build/fosforo.app/Contents/Info.plist
	codesign --force --sign - build/fosforo.app

# iOS simulator bundle, ad-hoc signed. The 3270 font is the repository's
# (BSD-3-Clause, assets/licenses/3270.txt, in the credits) and is registered
# by the app at launch.
FONT_3270 ?= assets/fonts/3270-Regular.otf
ios-sim: xcframework icons
	cd swift && xcodebuild -scheme fosforo-ios -destination 'generic/platform=iOS Simulator' \
		ARCHS=arm64 -derivedDataPath ../build/dd-ios -quiet build
	rm -rf build/fosforo-sim.app
	mkdir -p build/fosforo-sim.app
	cp build/dd-ios/Build/Products/Debug-iphonesimulator/fosforo-ios build/fosforo-sim.app/fosforo
	cp assets/Info-iOS.plist build/fosforo-sim.app/Info.plist
	cp assets/PrivacyInfo.xcprivacy build/fosforo-sim.app/
	if [ -f "$(FONT_3270)" ]; then cp "$(FONT_3270)" build/fosforo-sim.app/; fi
	cp assets/banner.ans build/icons/AppIcon*.png build/fosforo-sim.app/
	plutil -lint build/fosforo-sim.app/Info.plist
	codesign --force --sign - build/fosforo-sim.app

# installs on the paired iPhone/iPad; DEVICE=name picks one (tools/ios-device.sh -h)
ios-device: xcframework icons
	FONT_3270="$(FONT_3270)" tools/ios-device.sh

qa: all fmt-check test tidy check swift-fmt swift-build swift-test

clean:
	rm -rf build swift/.build

# The Mac build for others: Developer ID, hardened runtime, notarized and
# stapled, zipped in build/ (nothing published). APPLE_NOTARY_PROFILE names
# the notarytool credentials; tools/release.sh -h has the rest.
release:
	tools/release.sh
