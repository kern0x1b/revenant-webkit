P=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export IOS_SDK=${IOS_SDK:-${THEOS:-$HOME/theos}/sdks/iPhoneOS13.7.sdk}
SDK=$IOS_SDK
conan install "$P" -pr:h "$P/profiles/revenant-armv7" -pr:b default --build=missing \
    --deployer=full_deploy --deployer-folder="$P/build/deps" \
    && . "$P/build/conan/armv7/ios6-deps.env"
