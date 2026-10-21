.PHONY: app run install clean test

app:
	./scripts/build-app.sh

# Installs to /Applications and opens that copy, so the app you use has one stable home.
run: install
	open /Applications/TheExplorer.app

install: app
	rm -rf /Applications/TheExplorer.app
	cp -R build.noindex/TheExplorer.app /Applications/
	@echo "Installed /Applications/TheExplorer.app"

test:
	swift test

clean:
	rm -rf .build build.noindex
