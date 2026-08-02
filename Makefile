.PHONY: run build win mac mac-x64

run:
	dotnet run --project REditor

build:
	./build.sh

win:
	./build.sh win

mac:
	./build.sh mac

mac-x64:
	./build.sh mac-x64
