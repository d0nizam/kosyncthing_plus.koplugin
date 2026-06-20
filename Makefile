# Makefile — KOSyncthing+
#
# Builds the clean install zip (runtime files only): exactly the asset that is
# attached to each GitHub Release. The LICENSE is bundled; everything else a user
# does not need at runtime — docs, dev tooling, tests, VCS metadata, build
# artifacts and the runtime-downloaded Syncthing binary — is excluded.
#
#   make build   -> produce kosyncthing_plus_koplugin.zip in the repo root
#   make clean   -> remove it
#
# Run from the repository root (the .koplugin directory itself).

ZIP_NAME = kosyncthing_plus_koplugin.zip

.PHONY: build clean

build:
	@echo ">> Building $(ZIP_NAME)"
	@rm -f $(ZIP_NAME)
	@zip -r -X -q $(ZIP_NAME) . \
		-x ".git/*" \
		-x ".github/*" \
		-x ".gitignore" \
		-x "Makefile" \
		-x "README.md" \
		-x "CHANGELOG.md" \
		-x "API.md" \
		-x "spec/*" \
		-x "assets/*" \
		-x "tools/*" \
		-x "syncthing" \
		-x "*.zip" \
		-x "*.tar.gz" \
		-x "*.DS_Store"
	@echo ">> Done: $(ZIP_NAME)"

clean:
	@rm -f $(ZIP_NAME)
