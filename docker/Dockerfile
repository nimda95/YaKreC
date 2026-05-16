FROM ghcr.io/cirruslabs/flutter:stable

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      clang lld llvm cmake ninja-build pkg-config binutils \
      libgtk-3-dev liblzma-dev libsecret-1-dev libstdc++-12-dev \
      libpulse-dev libasound2-dev libjsoncpp-dev libsrtp2-dev \
      file desktop-file-utils libfuse2 wget ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 # native_toolchain_c (transitive dep via permission_handler / multicast_dns)
 # looks up the archiver inside /usr/lib/llvm-N/bin/ rather than $PATH. The
 # llvm package puts llvm-ar in /usr/bin; symlink it into every llvm-* dir
 # that exists so the lookup succeeds regardless of the major version the
 # base image ships with.
 && for d in /usr/lib/llvm-*; do \
      if [ -d "$d/bin" ] && [ ! -e "$d/bin/llvm-ar" ]; then \
        ln -s /usr/bin/llvm-ar "$d/bin/llvm-ar"; \
      fi; \
      if [ -d "$d/bin" ] && [ ! -e "$d/bin/ar" ]; then \
        ln -s /usr/bin/ar "$d/bin/ar"; \
      fi; \
    done

# AppImage tooling. Containers without FUSE can't run the AppImage directly,
# so extract it once and call its AppRun.
RUN wget -q -O /tmp/appimagetool.AppImage \
      https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage \
 && chmod +x /tmp/appimagetool.AppImage \
 && cd /opt && /tmp/appimagetool.AppImage --appimage-extract \
 && mv squashfs-root /opt/appimagetool \
 && ln -sf /opt/appimagetool/AppRun /usr/local/bin/appimagetool \
 && rm /tmp/appimagetool.AppImage

RUN flutter config --no-analytics --enable-linux-desktop \
 && flutter precache --linux --android \
 && flutter doctor -v

WORKDIR /workspace
