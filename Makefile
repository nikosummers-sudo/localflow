.PHONY: build app run smoke clean

# Compile the release binaries (LocalFlow + SttSmokeCheck).
build:
	swift build -c release

# Assemble and ad-hoc sign build/LocalFlow.app.
app: build
	bash Scripts/build-app.sh

# Build, assemble, and launch the app.
run: app
	open build/LocalFlow.app

# Offline transcription smoke test using the small "base" model.
smoke: build
	@mkdir -p build/smoke
	say -o build/smoke/smoke.aiff "The quick brown fox jumps over the lazy dog"
	afconvert -f WAVE -d LEI16@16000 -c 1 build/smoke/smoke.aiff build/smoke/smoke.wav
	.build/release/SttSmokeCheck build/smoke/smoke.wav base

clean:
	rm -rf .build build
