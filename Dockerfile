FROM perl:5.32.1-threaded

ENV LANG C.UTF-8
ENV TZ Asia/Tokyo

ARG uid=1000
ARG gid=1000

RUN cpanm -nq Carmel && \
    useradd app -ms /bin/bash -u $uid && \
    groupmod -g $gid app
USER app

WORKDIR /app
