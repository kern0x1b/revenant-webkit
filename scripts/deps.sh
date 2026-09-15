P=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export IOS_SDK=${IOS_SDK:-${THEOS:-$HOME/theos}/sdks/iPhoneOS13.7.sdk}
SDK=$IOS_SDK
conan install "$P" -pr:h ios6-armv7 -pr:b default --build=missing \
    --deployer=full_deploy --deployer-folder="$P/build/deps" \
    && . "$P/build/conan/ios6-deps.env"
