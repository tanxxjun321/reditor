.PHONY: run build mac mac-x64 bridge sign

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

# 签名证书由 sign.sh 自动探测钥匙串里的 Developer ID Application;
# notarytool 凭据名固定为 airmirror-notary(配置见 sign.sh 头部注释)
sign:
	./sign.sh publish/AirMirror.app