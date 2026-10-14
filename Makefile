.PHONY: app run install clean

app:
	./scripts/build-app.sh

run: app
	open build/TheExplorer.app

# Copies the app to /Applications so it has a stable home for Full Disk Access.
install: app
	rm -rf /Applications/TheExplorer.app
	cp -R build/TheExplorer.app /Applications/
	@echo "Installed /Applications/TheExplorer.app"

clean:
	rm -rf .build build
