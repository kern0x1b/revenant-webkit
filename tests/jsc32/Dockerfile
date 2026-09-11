# A 32-bit ARM JavaScriptCore, built to be run under emulation on a 64-bit host.
#
# The phone's engine and this one share the part of JavaScriptCore that is most
# expensive to carry: the 32-bit JSValue representation and the ARMv7 JIT, both
# of which upstream deleted. Neither needs iOS to run, so they can be tested
# here, against JavaScriptCore's own suites, with no device in the loop.
#
# The compiler runs natively and targets armhf; only the resulting binary is
# emulated, so the build costs what a normal build costs.
FROM debian:bookworm

RUN dpkg --add-architecture armhf && apt-get update && apt-get install -y --no-install-recommends \
        crossbuild-essential-armhf libicu-dev:armhf zlib1g-dev:armhf \
        build-essential perl gdb-multiarch \
        cmake ninja-build ruby python3 git ca-certificates qemu-user-static \
    && rm -rf /var/lib/apt/lists/*

COPY armhf.cmake /armhf.cmake
WORKDIR /src
