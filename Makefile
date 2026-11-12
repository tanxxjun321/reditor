.PHONY: run build win mac mac-x64 bridge

run: bridge
	dotnet run --project REditor

bridge:
	./native/build.sh

build:
	./build.sh

win:
	./build.sh win

mac:
	./build.sh mac

mac-x64:
	./build.sh mac-x64
