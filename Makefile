.PHONY: app run install test clean

app:
	./scripts/bundle.sh

run: app
	open build/TheWatcher.app

install: app
	pkill -x TheWatcher || true
	while pgrep -x TheWatcher >/dev/null; do sleep 0.2; done
	rm -rf /Applications/TheWatcher.app
	cp -R build/TheWatcher.app /Applications/
	open /Applications/TheWatcher.app

test:
	swift test

clean:
	swift package clean
	rm -rf build
