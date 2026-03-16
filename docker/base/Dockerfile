FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    curl \
    wget \
    git \
    unzip \
    sudo \
    ca-certificates \
    gnupg \
    lsb-release \
    && rm -rf /var/lib/apt/lists/*

# Create a non-root user for the project
ARG PROJECT_USER=app
RUN useradd -m -s /bin/bash ${PROJECT_USER} \
    && echo "${PROJECT_USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${PROJECT_USER}

USER ${PROJECT_USER}
WORKDIR /home/${PROJECT_USER}

CMD ["/bin/bash"]
