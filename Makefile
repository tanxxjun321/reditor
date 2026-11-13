.PHONY: run build mac mac-x64 bridge

run: bridge
	dotnet run --project AirMirror

bridge:
	./native/build.sh

build:
	./build.sh

mac:
	./build.sh mac

mac-x64:
	./build.sh mac-x64

sign:
	SIGN_IDENTITY="Apple Distribution: Ling Ling Xie (5DF5Z5B263)" NOTARY_PROFILE=airmirror-notary ./sign.sh publish/AirMirror.app