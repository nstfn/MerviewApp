WEB := MerviewApp/Resources/web

.PHONY: sync vendor project setup build run clean

## Sync merview submodule assets into Resources/web and apply offline patches
sync:
	@echo "Syncing merview submodule -> Resources/web..."
	@rsync -a --delete merview/js/ $(WEB)/js/
	@rsync -a --delete merview/styles/ $(WEB)/styles/
	@rsync -a --delete merview/docs/ $(WEB)/docs/
	@rsync -a --delete merview/images/ $(WEB)/images/
	@cp merview/favicon.png $(WEB)/favicon.png
	@echo "Applying offline patches..."
	@cd $(WEB) && patch -p1 --forward < ../../../patches/themes-offline.patch || true
	@cd $(WEB) && patch -p1 --forward < ../../../patches/fullscreen-fixes.patch || true
	@cd $(WEB) && patch -p1 --forward < ../../../patches/preview-fullscreen.patch || true
	@cd $(WEB) && patch -p1 --forward < ../../../patches/layout-constraints.patch || true
	@echo "Sync complete."

## Download vendor libraries (CDN deps bundled for offline use)
vendor:
	@echo "Downloading vendor libraries..."
	@mkdir -p $(WEB)/vendor/codemirror/mode $(WEB)/vendor/codemirror/addon $(WEB)/vendor/hljs-themes
	@curl -sL "https://cdn.jsdelivr.net/npm/marked@11.1.1/marked.min.js"            -o $(WEB)/vendor/marked.min.js
	@curl -sL "https://cdn.jsdelivr.net/npm/mermaid@11.12.2/dist/mermaid.min.js"     -o $(WEB)/vendor/mermaid.min.js
	@curl -sL "https://cdn.jsdelivr.net/npm/dompurify@3.2.2/dist/purify.min.js"      -o $(WEB)/vendor/purify.min.js
	@curl -sL "https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/highlight.min.js" -o $(WEB)/vendor/highlight.min.js
	@curl -sL "https://cdnjs.cloudflare.com/ajax/libs/codemirror/5.65.18/codemirror.min.css" -o $(WEB)/vendor/codemirror/codemirror.min.css
	@curl -sL "https://cdnjs.cloudflare.com/ajax/libs/codemirror/5.65.18/codemirror.min.js"  -o $(WEB)/vendor/codemirror/codemirror.min.js
	@for mode in markdown gfm javascript xml css yaml python; do \
		curl -sL "https://cdnjs.cloudflare.com/ajax/libs/codemirror/5.65.18/mode/$$mode/$$mode.min.js" \
			-o "$(WEB)/vendor/codemirror/mode/$$mode.min.js"; \
	done
	@curl -sL "https://cdnjs.cloudflare.com/ajax/libs/codemirror/5.65.18/addon/edit/continuelist.min.js" -o $(WEB)/vendor/codemirror/addon/continuelist.min.js
	@curl -sL "https://cdnjs.cloudflare.com/ajax/libs/codemirror/5.65.18/addon/mode/overlay.min.js"     -o $(WEB)/vendor/codemirror/addon/overlay.min.js
	@for theme in github-dark github vs2015 monokai atom-one-dark atom-one-light nord tokyo-night-dark tokyo-night-light night-owl obsidian agate; do \
		curl -sL "https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/styles/$$theme.min.css" \
			-o "$(WEB)/vendor/hljs-themes/$$theme.min.css"; \
	done
	@echo "Vendor libraries downloaded."

## Generate Xcode project from project.yml
project:
	@xcodegen generate

## Full first-time setup: sync submodule assets + download vendor libs + generate Xcode project
setup: sync vendor project
	@echo "Setup complete. Open MerviewApp.xcodeproj or run: make build"

## Build the app
build: project
	@xcodebuild -project MerviewApp.xcodeproj -scheme MerviewApp -configuration Debug build | tail -3

## Build and run
run: build
	@open "$$(xcodebuild -project MerviewApp.xcodeproj -scheme MerviewApp -configuration Debug \
		-showBuildSettings 2>/dev/null | grep -m1 'BUILT_PRODUCTS_DIR' | awk '{print $$NF}')/Merview.app"

## Clean build artifacts
clean:
	@xcodebuild -project MerviewApp.xcodeproj -scheme MerviewApp clean 2>/dev/null || true
	@rm -rf MerviewApp.xcodeproj MerviewApp/Info.plist
