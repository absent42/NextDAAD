# Linux parity rig. Context = tests/out/docker-context (staged by tests/kit-linux.ps1).
# Ubuntu 24.04 has no sjasmplus package: built from the pinned source tarball.
FROM ubuntu:24.04 AS sjasm
ARG SJASMPLUS_VER
RUN apt-get update && apt-get install -y --no-install-recommends build-essential xz-utils ca-certificates wget \
 && wget -qO /tmp/s.tar.xz "https://github.com/z00m128/sjasmplus/releases/download/v${SJASMPLUS_VER}/sjasmplus-${SJASMPLUS_VER}-src.tar.xz" \
 && mkdir /tmp/s && tar -xJf /tmp/s.tar.xz -C /tmp/s --strip-components=1 \
 && make -C /tmp/s -j"$(nproc)" && install -m755 /tmp/s/sjasmplus /opt/sjasmplus

FROM ubuntu:24.04
ARG ARKOS_VER
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates wget unzip zip git procps ffmpeg python3 python3-venv \
 && wget -qO /tmp/ms.deb https://packages.microsoft.com/config/ubuntu/24.04/packages-microsoft-prod.deb \
 && dpkg -i /tmp/ms.deb && apt-get update && apt-get install -y --no-install-recommends powershell \
 && rm -rf /var/lib/apt/lists/* /tmp/ms.deb
COPY context/ArkosTracker-linux64-${ARKOS_VER}.zip /tmp/arkos.zip
RUN mkdir -p /opt/kittools/sjasmplus \
 && unzip -q /tmp/arkos.zip 'ArkosTracker3/tools/*' -d /opt/kittools \
 && chmod +x /opt/kittools/ArkosTracker3/tools/* && rm /tmp/arkos.zip
COPY --from=sjasm /opt/sjasmplus /opt/kittools/sjasmplus/sjasmplus
COPY repo/ /work/
COPY exec-list.txt /work/exec-list.txt
# COPY assigns its own modes to a Windows context: clear them all, then apply
# git's index list, then snapshot as a repo so parity.ps1's git ls-files works.
RUN cd /work && find . -type f -exec chmod 644 {} + && xargs -a exec-list.txt chmod +x && rm exec-list.txt \
 && git init -q && git add -A && git -c user.name=rig -c user.email=rig@localhost commit -qm snapshot \
 && python3 -m venv /opt/venv && /opt/venv/bin/pip install -q -r authoring-kit/lib/requirements.txt pytest
ENV PATH=/opt/venv/bin:$PATH
WORKDIR /work
ENTRYPOINT ["pwsh", "-NoProfile", "-File", "tests/kit-parity/docker-entry.ps1"]
